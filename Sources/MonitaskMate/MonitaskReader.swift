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
        if isTracking, let latestPeriod, periodIsFresh {
            let elapsed = Int(now.timeIntervalSince(latestPeriod.dateStart))
            activeSeconds = max(Int(latestPeriod.duration), max(0, elapsed))
        } else if isTracking,
                  let latestLogEvent,
                  latestLogEvent.type == .start {
            let startTime = latestLogEvent.eventTime
            activeSeconds = max(0, Int(now.timeIntervalSince(startTime)))
        }

        return TrackingSnapshot(
            isTracking: isTracking,
            totalSeconds: savedSeconds + activeSeconds,
            activeSeconds: activeSeconds,
            selectedProjectName: selectedProject?.name ?? "Unknown",
            lastUpdated: now
        )
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

        let text = try String(contentsOf: newestLog, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)

        for line in lines.reversed() {
            if let event = parseTrackingEvent(from: String(line)) {
                return event
            }
        }

        return nil
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

        let rawDate = String(line[start..<end])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let parsed = formatter.date(from: rawDate) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawDate)
    }

    private func parsePCTime(_ line: String) -> Date? {
        guard let range = line.range(of: "PC Time: \"") else {
            return nil
        }

        let start = range.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else {
            return nil
        }

        let rawDate = String(line[start..<end])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let parsed = formatter.date(from: rawDate) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: rawDate)
    }
}
