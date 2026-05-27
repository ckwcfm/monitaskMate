import Foundation

struct MonitaskReader {
    private let fileManager = FileManager.default
    private let isoDecoder: JSONDecoder

    private let monitaskRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Monitask", isDirectory: true)

    private enum TrackingEventType {
        case start
        case stop
    }

    private struct TrackingEvent {
        let type: TrackingEventType
        let timestamp: Date
        let eventTime: Date
    }

    private struct LogFileSignature: Hashable {
        let path: String
        let modificationTime: TimeInterval
        let fileSize: Int64
    }

    private struct LogEventCacheEntry {
        let signature: LogFileSignature
        let event: TrackingEvent?
    }

    private struct MonthlyStats {
        let totalSeconds: Int
    }

    private struct MonthlyStatsCacheKey: Hashable {
        let year: Int
        let month: Int
        let day: Int
        let projectId: String?
    }

    private struct MonthlyStatsCacheEntry {
        let key: MonthlyStatsCacheKey
        let stats: MonthlyStats
        let expiresAt: TimeInterval
    }

    private struct BackupPeriodEnvelope: Decodable {
        let period: BackupPeriod
        let activities: [String: String]

        enum CodingKeys: String, CodingKey {
            case period = "Period"
            case activities = "Activities"
        }
    }

    private struct BackupPeriod: Decodable {
        let id: String
        let projectId: String
        let dateStart: Date

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case projectId = "ProjectId"
            case dateStart = "DateStart"
        }
    }

    private static let logEventCacheLock = NSLock()
    private static var logEventCacheEntry: LogEventCacheEntry?
    private static let monthlyStatsCacheLock = NSLock()
    private static var monthlyStatsCacheEntry: MonthlyStatsCacheEntry?

    static func invalidateCaches() {
        logEventCacheLock.lock()
        logEventCacheEntry = nil
        logEventCacheLock.unlock()

        monthlyStatsCacheLock.lock()
        monthlyStatsCacheEntry = nil
        monthlyStatsCacheLock.unlock()
    }

    init() {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            if let date = formatter.date(from: rawValue) {
                return date
            }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: rawValue) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(rawValue)")
        }
        isoDecoder = decoder
    }

    func loadSnapshot(now: Date = Date()) throws -> TrackingSnapshot {
        let settings = try loadSettings()
        let info = try loadProjectInfo()
        let latestPeriod = try loadLatestPeriod()

        let selectedProject = pickProject(from: info.projects, selectedProjectId: settings?.lastSelectedProjectId)
        let savedSeconds = Int(selectedProject?.duration ?? 0)

        let periodIsFresh: Bool
        if let latestPeriod {
            periodIsFresh = now.timeIntervalSince(latestPeriod.dateLastActive) <= 90
        } else {
            periodIsFresh = false
        }

        let latestLogEvent: TrackingEvent?
        if periodIsFresh {
            latestLogEvent = nil
        } else {
            latestLogEvent = try loadLatestTrackingEvent()
        }

        let logSaysTracking: Bool
        if let latestLogEvent,
           latestLogEvent.type == .start {
            logSaysTracking = true
        } else {
            logSaysTracking = false
        }

        let isTracking = periodIsFresh || logSaysTracking

        var activeSeconds = 0
        var activeSessionStart: Date?
        if isTracking, let latestPeriod, periodIsFresh {
            activeSessionStart = latestPeriod.dateStart
            let elapsedSinceLastActive = Int(now.timeIntervalSince(latestPeriod.dateLastActive))
            activeSeconds = Int(latestPeriod.duration) + max(0, elapsedSinceLastActive)
        } else if isTracking,
                  let latestLogEvent,
                  latestLogEvent.type == .start {
            let startTime = latestLogEvent.eventTime
            activeSessionStart = startTime
            activeSeconds = max(0, Int(now.timeIntervalSince(startTime)))
        }

        let monthlyStats = try loadMonthlyStats(now: now, activeSessionStart: activeSessionStart, activeSeconds: activeSeconds)
        let todayActivityPercent = try loadTodayActivityPercent(now: now, selectedProjectId: selectedProject?.id)

        return TrackingSnapshot(
            isTracking: isTracking,
            totalSeconds: savedSeconds + activeSeconds,
            activeSeconds: activeSeconds,
            monthlyTotalSeconds: monthlyStats.totalSeconds,
            todayActivityPercent: todayActivityPercent,
            selectedProjectName: selectedProject?.name ?? "Unknown",
            lastActiveAt: latestPeriod?.dateLastActive,
            lastUpdated: now
        )
    }

    private func loadMonthlyStats(now: Date, activeSessionStart: Date?, activeSeconds: Int) throws -> MonthlyStats {
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.year, .month], from: now)
        let cacheKey = MonthlyStatsCacheKey(
            year: nowComponents.year ?? 0,
            month: nowComponents.month ?? 0,
            day: calendar.component(.day, from: now),
            projectId: nil
        )

        let stoppedTotal: Int
        if let cached = cachedMonthlyStats(for: cacheKey, now: now) {
            stoppedTotal = cached.totalSeconds
        } else {
            let trackedTotal = try loadMonthlyTotalFromLogs(now: now)
            let idleTotal = try loadMonthlyIdleSecondsFromLogs(now: now)
            stoppedTotal = max(0, trackedTotal - idleTotal)
            storeMonthlyStats(MonthlyStats(totalSeconds: stoppedTotal), for: cacheKey, now: now)
        }

        let activeTotal = currentMonthActiveSeconds(now: now, activeSessionStart: activeSessionStart, activeSeconds: activeSeconds)
        return MonthlyStats(totalSeconds: stoppedTotal + activeTotal)
    }

    private func loadTodayActivityPercent(now: Date, selectedProjectId: String?) throws -> Double? {
        let periodsURL = monitaskRoot.appendingPathComponent("Periods", isDirectory: true)
        let files: [URL]
        if fileManager.fileExists(atPath: periodsURL.path) {
            files = try fileManager.contentsOfDirectory(at: periodsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "json" }
        } else {
            files = []
        }

        var totalUnits = 0
        var activeUnits = 0
        var seenActivityKeys = Set<String>()
        let calendar = Calendar.current

        for file in files {
            let data = try Data(contentsOf: file)
            let period = try isoDecoder.decode(MonitaskPeriod.self, from: data)

            if let selectedProjectId, period.projectId != selectedProjectId {
                continue
            }

            guard calendar.isDate(period.dateStart, inSameDayAs: now),
                  let slices = period.activitys else {
                continue
            }

            for (index, slice) in slices.enumerated() {
                let key = activitySampleKey(periodId: period.id, date: slice.date, fallback: String(index))
                guard seenActivityKeys.insert(key).inserted else {
                    continue
                }
                accumulateActivity([slice.data], activeUnits: &activeUnits, totalUnits: &totalUnits)
            }
        }

        try loadTodayBackupActivityData(now: now, selectedProjectId: selectedProjectId).forEach { sample in
            guard seenActivityKeys.insert(sample.key).inserted else {
                return
            }
            accumulateActivity([sample.data], activeUnits: &activeUnits, totalUnits: &totalUnits)
        }

        guard totalUnits > 0 else {
            return nil
        }
        return Double(activeUnits) / Double(totalUnits) * 100
    }

    private func accumulateActivity(_ values: [String], activeUnits: inout Int, totalUnits: inout Int) {
        for value in values {
            for character in value {
                if character == "1" {
                    activeUnits += 1
                    totalUnits += 1
                } else if character == "0" {
                    totalUnits += 1
                }
            }
        }
    }

    private func loadTodayBackupActivityData(now: Date, selectedProjectId: String?) throws -> [(key: String, data: String)] {
        let backupsURL = monitaskRoot.appendingPathComponent("Backups", isDirectory: true)
        guard fileManager.fileExists(atPath: backupsURL.path) else {
            return []
        }

        let calendar = Calendar.current
        let todayInterval = calendar.dateInterval(of: .day, for: now)
        let files = try fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { file in
                guard file.pathExtension.lowercased() == "zip" else {
                    return false
                }
                guard let todayInterval,
                      let backupDate = backupDate(from: file) else {
                    return false
                }
                return todayInterval.contains(backupDate)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var result: [(key: String, data: String)] = []

        for file in files {
            guard let data = unzipFirstFile(at: file),
                  let envelope = try? isoDecoder.decode(BackupPeriodEnvelope.self, from: data) else {
                continue
            }

            if let selectedProjectId, envelope.period.projectId != selectedProjectId {
                continue
            }

            guard calendar.isDate(envelope.period.dateStart, inSameDayAs: now),
                  !envelope.activities.isEmpty else {
                continue
            }

            for (activityDate, data) in envelope.activities {
                let parsedDate = parseISO8601Date(activityDate)
                let key = activitySampleKey(periodId: envelope.period.id, date: parsedDate, fallback: activityDate)
                result.append((key: key, data: data))
            }
        }

        return result
    }

    private func activitySampleKey(periodId: String, date: Date?, fallback: String) -> String {
        guard let date else {
            return "\(periodId)|\(fallback)"
        }
        return "\(periodId)|\(Int(date.timeIntervalSince1970))"
    }

    private func backupDate(from url: URL) -> Date? {
        guard let match = url.deletingPathExtension().lastPathComponent.firstMatch(of: /_(\d{17,})$/),
              let ticks = Int64(match.output.1) else {
            return nil
        }

        let windowsEpochOffsetSeconds: TimeInterval = 62_135_596_800
        let seconds = TimeInterval(ticks) / 10_000_000 - windowsEpochOffsetSeconds
        return Date(timeIntervalSince1970: seconds)
    }

    private func unzipFirstFile(at url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private func currentMonthActiveSeconds(now: Date, activeSessionStart: Date?, activeSeconds: Int) -> Int {
        guard let activeSessionStart, activeSeconds > 0 else {
            return 0
        }

        let calendar = Calendar.current
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else {
            return activeSeconds
        }

        if activeSessionStart < monthStart {
            return min(activeSeconds, max(0, Int(now.timeIntervalSince(monthStart))))
        }

        return activeSeconds
    }

    private func loadMonthlyTotalFromLogs(now: Date) throws -> Int {
        let pattern = /\|(\d+)\s*;/
        var total = 0

        for line in try currentMonthLogLines(now: now) where line.contains("Stop time tracking") {
            if let match = line.firstMatch(of: pattern),
               let value = Int(match.output.1) {
                total += value
            }
        }

        return total
    }

    private func loadMonthlyIdleSecondsFromLogs(now: Date) throws -> Int {
        let lines = try currentMonthLogLines(now: now)
        let idlePattern = /Downtime by idle - "([^"]+)" "([^"]+)"/
        let stopPattern = /Stop time tracking "([^"]+)"\|(\d+)\s*;/
        var sessionStarts: [String: Date] = [:]
        var sessions: [(start: Date, end: Date, duration: Int)] = []
        var idleIntervals: [(start: Date, end: Date)] = []

        for line in lines {
            if line.contains("Start time tracking"),
               let event = parseTrackingEvent(from: line),
               let id = parseTrackingId(from: line) {
                sessionStarts[id] = event.eventTime
            } else if line.contains("Stop time tracking"),
                      let match = line.firstMatch(of: stopPattern),
                      let event = parseTrackingEvent(from: line),
                      let duration = Int(match.output.2),
                      let start = sessionStarts[String(match.output.1)] {
                sessions.append((start: start, end: event.eventTime, duration: duration))
            } else if line.contains("Downtime by idle"),
                      let match = line.firstMatch(of: idlePattern),
                      let start = parseISO8601Date(String(match.output.1)),
                      let end = parseISO8601Date(String(match.output.2)) {
                idleIntervals.append((start: start, end: end))
            }
        }

        var total = 0
        for idle in idleIntervals {
            let idleSeconds = max(0, Int(idle.end.timeIntervalSince(idle.start)))
            guard sessions.contains(where: { session in
                idle.start >= session.start
                    && idle.start <= session.end
                    && session.duration >= idleSeconds
            }) else {
                continue
            }
            total += idleSeconds
        }

        return total
    }

    private func currentMonthLogLines(now: Date) throws -> [String] {
        let logsURL = monitaskRoot.appendingPathComponent("Logs", isDirectory: true)
        guard fileManager.fileExists(atPath: logsURL.path) else {
            return []
        }

        let files = try fileManager.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "txt" && $0.lastPathComponent.hasPrefix("log") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let calendar = Calendar.current
        let current = calendar.dateComponents([.year, .month], from: now)
        var lines: [String] = []

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.count == 11 else { continue }

            let ymd = name.suffix(8)
            guard let year = Int(ymd.prefix(4)),
                  let month = Int(ymd.dropFirst(4).prefix(2)),
                  year == current.year,
                  month == current.month else {
                continue
            }

            let text = try String(contentsOf: file, encoding: .utf8)
            lines.append(contentsOf: text.split(whereSeparator: \.isNewline).map(String.init))
        }

        return lines
    }

    private func loadSettings() throws -> MonitaskSettings? {
        let settingsURL = monitaskRoot.appendingPathComponent("Settings.json")
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: settingsURL)
        return try isoDecoder.decode(MonitaskSettings.self, from: data)
    }

    private func loadProjectInfo() throws -> ProjectInfo {
        let projectInfoURL = monitaskRoot.appendingPathComponent("ProjectInfo.json")
        let data = try Data(contentsOf: projectInfoURL)
        return try isoDecoder.decode(ProjectInfo.self, from: data)
    }

    private func loadLatestPeriod() throws -> MonitaskPeriod? {
        let periodsURL = monitaskRoot.appendingPathComponent("Periods", isDirectory: true)
        guard fileManager.fileExists(atPath: periodsURL.path) else {
            return nil
        }

        let files = try fileManager.contentsOfDirectory(at: periodsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension.lowercased() == "json" }

        guard !files.isEmpty else {
            return nil
        }

        let newest = try files.max { lhs, rhs in
            let leftDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rightDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return leftDate < rightDate
        }

        guard let newest else {
            return nil
        }

        let data = try Data(contentsOf: newest)
        return try isoDecoder.decode(MonitaskPeriod.self, from: data)
    }

    private func pickProject(from projects: [Project], selectedProjectId: String?) -> Project? {
        if let selectedProjectId,
           let selected = projects.first(where: { $0.id == selectedProjectId }) {
            return selected
        }
        return projects.first
    }

    private func loadLatestTrackingEvent() throws -> TrackingEvent? {
        let logsURL = monitaskRoot.appendingPathComponent("Logs", isDirectory: true)
        guard fileManager.fileExists(atPath: logsURL.path) else {
            return nil
        }

        let files = try fileManager.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("log") && $0.pathExtension.lowercased() == "txt" }

        guard !files.isEmpty else {
            return nil
        }

        let newestLog = try files.max { lhs, rhs in
            let leftDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rightDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return leftDate < rightDate
        }

        guard let newestLog else {
            return nil
        }

        let resourceValues = try newestLog.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let signature = LogFileSignature(
            path: newestLog.path,
            modificationTime: (resourceValues.contentModificationDate ?? .distantPast).timeIntervalSinceReferenceDate,
            fileSize: Int64(resourceValues.fileSize ?? 0)
        )

        if let cached = cachedTrackingEvent(for: signature) {
            return cached
        }

        let text = try String(contentsOf: newestLog, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)

        for line in lines.reversed() {
            if let event = parseTrackingEvent(from: String(line)) {
                storeCachedTrackingEvent(event, for: signature)
                return event
            }
        }

        storeCachedTrackingEvent(nil, for: signature)

        return nil
    }

    private func cachedTrackingEvent(for signature: LogFileSignature) -> TrackingEvent?? {
        Self.logEventCacheLock.lock()
        defer { Self.logEventCacheLock.unlock() }
        guard let entry = Self.logEventCacheEntry, entry.signature == signature else {
            return nil
        }
        return entry.event
    }

    private func storeCachedTrackingEvent(_ event: TrackingEvent?, for signature: LogFileSignature) {
        Self.logEventCacheLock.lock()
        Self.logEventCacheEntry = LogEventCacheEntry(signature: signature, event: event)
        Self.logEventCacheLock.unlock()
    }

    private func cachedMonthlyStats(for key: MonthlyStatsCacheKey, now: Date) -> MonthlyStats? {
        Self.monthlyStatsCacheLock.lock()
        defer { Self.monthlyStatsCacheLock.unlock() }
        guard let entry = Self.monthlyStatsCacheEntry,
              entry.key == key,
              now.timeIntervalSinceReferenceDate < entry.expiresAt else {
            return nil
        }
        return entry.stats
    }

    private func storeMonthlyStats(_ stats: MonthlyStats, for key: MonthlyStatsCacheKey, now: Date) {
        Self.monthlyStatsCacheLock.lock()
        Self.monthlyStatsCacheEntry = MonthlyStatsCacheEntry(
            key: key,
            stats: stats,
            expiresAt: now.timeIntervalSinceReferenceDate + 60
        )
        Self.monthlyStatsCacheLock.unlock()
    }

    private func parseTrackingId(from line: String) -> String? {
        guard let trackingRange = line.range(of: "time tracking \"") else {
            return nil
        }
        let start = trackingRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else {
            return nil
        }
        return String(line[start..<end])
    }

    private func parseTrackingEvent(from line: String) -> TrackingEvent? {
        let type: TrackingEventType
        if line.contains("Start time tracking") {
            type = .start
        } else if line.contains("Stop time tracking") {
            type = .stop
        } else {
            return nil
        }

        guard let timestamp = parseLogTimestamp(line) else {
            return nil
        }

        let eventTime = parsePCTime(line) ?? parseAppTime(line) ?? timestamp
        return TrackingEvent(type: type, timestamp: timestamp, eventTime: eventTime)
    }

    private func parseLogTimestamp(_ line: String) -> Date? {
        guard line.count >= 30 else {
            return nil
        }
        let rawPrefix = String(line.prefix(30))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return formatter.date(from: rawPrefix)
    }

    private func parseAppTime(_ line: String) -> Date? {
        guard let range = line.range(of: "App Time: \"") ?? line.range(of: "AppTime: \"") else {
            return nil
        }

        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else {
            return nil
        }

        return parseISO8601Date(String(line[start..<end]))
    }

    private func parsePCTime(_ line: String) -> Date? {
        guard let range = line.range(of: "PC Time: \"") else {
            return nil
        }

        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else {
            return nil
        }

        return parseISO8601Date(String(line[start..<end]))
    }

    private func parseISO8601Date(_ rawDate: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let parsed = formatter.date(from: rawDate) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawDate)
    }
}
