import Foundation
import SwiftUI
import AppKit

@MainActor
final class TrackingViewModel: ObservableObject {
    enum CounterDisplayFormat: String, CaseIterable, Identifiable {
        case hoursMinutes = "hm"
        case hoursMinutesSeconds = "hms"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .hoursMinutes:
                return "Hours + Minutes"
            case .hoursMinutesSeconds:
                return "Hours + Minutes + Seconds"
            }
        }

        var description: String {
            switch self {
            case .hoursMinutes:
                return "Shows values like 3h 24m"
            case .hoursMinutesSeconds:
                return "Shows values like 3h 24m 18s"
            }
        }
    }

    enum CounterUpdateMethod: String, CaseIterable, Identifiable {
        case authoritative = "authoritative"
        case localTicker = "localTicker"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .authoritative:
                return "Authoritative"
            case .localTicker:
                return "Local Ticker"
            }
        }

        var description: String {
            switch self {
            case .authoritative:
                return "Follows Monitask files exactly on each sync; safest for strict accuracy."
            case .localTicker:
                return "Starts from Monitask data, then increments locally every second while tracking and auto-resyncs if drift is detected."
            }
        }
    }

    enum RefreshInterval: Int, CaseIterable, Identifiable {
        case oneSecond = 1
        case tenSeconds = 10
        case thirtySeconds = 30
        case oneMinute = 60

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .oneSecond:
                return "1 second"
            case .tenSeconds:
                return "10 seconds"
            case .thirtySeconds:
                return "30 seconds"
            case .oneMinute:
                return "1 minute"
            }
        }

        var timerTolerance: TimeInterval {
            switch self {
            case .oneSecond:
                return 0.2
            case .tenSeconds:
                return 1
            case .thirtySeconds:
                return 2
            case .oneMinute:
                return 4
            }
        }
    }

    @Published private(set) var snapshot = TrackingSnapshot(
        isTracking: false,
        totalSeconds: 0,
        activeSeconds: 0,
        monthlyTotalSeconds: 0,
        todayActivityPercent: nil,
        selectedProjectName: "Loading",
        lastActiveAt: nil,
        lastUpdated: Date()
    )
    @Published private(set) var loadError: String?
    @Published private(set) var menuBarLabelImage: NSImage
    @Published var counterDisplayFormat: CounterDisplayFormat {
        didSet {
            UserDefaults.standard.set(counterDisplayFormat.rawValue, forKey: Self.counterDisplayFormatKey)
            updateCounterPresentation()
        }
    }
    @Published var counterUpdateMethod: CounterUpdateMethod {
        didSet {
            UserDefaults.standard.set(counterUpdateMethod.rawValue, forKey: Self.counterUpdateMethodKey)
            applyCounterUpdateMethodChange()
        }
    }
    @Published var refreshInterval: RefreshInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: Self.refreshIntervalKey)
            configureRefreshTimer()
        }
    }
    @Published private(set) var scheduledPauseRemainingSeconds: Int?

    private let reminderManager: ReminderManager
    private let floatingCounterManager: FloatingCounterManager
    private let autoPauseManager: AutoPauseManager
    private let controlService: MonitaskControlService
    private var refreshTimer: Timer?
    private var localTickerTimer: Timer?
    private var displayedTotalSeconds = 0
    private var isRefreshing = false
    private var pendingRefresh = false
    private var pendingForceRefresh = false
    private var scheduledPauseTask: Task<Void, Never>?
    private var actionRefreshTask: Task<Void, Never>?

    private static let refreshIntervalKey = "tracking.refreshIntervalSeconds"
    private static let counterDisplayFormatKey = "tracking.counterDisplayFormat"
    private static let counterUpdateMethodKey = "tracking.counterUpdateMethod"
    private static let localTickerDriftSnapThreshold = 2

    init(
        reminderManager: ReminderManager,
        floatingCounterManager: FloatingCounterManager,
        autoPauseManager: AutoPauseManager,
        controlService: MonitaskControlService
    ) {
        self.reminderManager = reminderManager
        self.floatingCounterManager = floatingCounterManager
        self.autoPauseManager = autoPauseManager
        self.controlService = controlService
        menuBarLabelImage = MenuBarLabelFactory.makeLabel(timeText: "00h 00m", isTracking: false, showSeconds: false)

        let storedDisplayFormat = UserDefaults.standard.string(forKey: Self.counterDisplayFormatKey)
        counterDisplayFormat = CounterDisplayFormat(rawValue: storedDisplayFormat ?? "") ?? .hoursMinutes

        let storedUpdateMethod = UserDefaults.standard.string(forKey: Self.counterUpdateMethodKey)
        counterUpdateMethod = CounterUpdateMethod(rawValue: storedUpdateMethod ?? "") ?? .authoritative

        let stored = UserDefaults.standard.integer(forKey: Self.refreshIntervalKey)
        refreshInterval = RefreshInterval(rawValue: stored) ?? .oneSecond
        scheduledPauseRemainingSeconds = nil

        controlService.refreshReadiness()
        refresh(forceReload: true)
        configureRefreshTimer()
    }

    private func configureRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval.rawValue), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refreshTimer?.tolerance = refreshInterval.timerTolerance
    }

    private func configureLocalTickerTimerIfNeeded() {
        localTickerTimer?.invalidate()
        localTickerTimer = nil

        guard counterUpdateMethod == .localTicker, snapshot.isTracking else {
            return
        }

        localTickerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceLocalTicker()
            }
        }
        localTickerTimer?.tolerance = 0.2
    }

    private func advanceLocalTicker() {
        guard counterUpdateMethod == .localTicker, snapshot.isTracking else {
            configureLocalTickerTimerIfNeeded()
            return
        }

        displayedTotalSeconds += 1
        updateCounterPresentation()
    }

    var menuBarTitle: String {
        formatForCounter(seconds: displayedTotalSeconds)
    }

    var floatingCounterTitle: String {
        formatForFloatingCounter(seconds: displayedTotalSeconds)
    }

    var statusColor: Color {
        snapshot.isTracking ? .green : .red
    }

    var statusDot: String {
        snapshot.isTracking ? "🟢" : "🔴"
    }

    var statusText: String {
        snapshot.isTracking ? "Tracking" : "Not Tracking"
    }

    var lastUpdatedText: String {
        Self.timeFormatter.string(from: snapshot.lastUpdated)
    }

    var refreshIntervalText: String {
        refreshInterval.label
    }

    var monthlyTotalText: String {
        format(seconds: snapshot.monthlyTotalSeconds)
    }

    var todayActivityText: String {
        guard let percent = snapshot.todayActivityPercent else {
            return "N/A"
        }
        return String(format: "%.0f%%", percent)
    }

    var scheduledPauseText: String? {
        guard let remaining = scheduledPauseRemainingSeconds else {
            return nil
        }
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "Pausing in %dm %02ds", minutes, seconds)
    }

    var hasScheduledPause: Bool {
        scheduledPauseRemainingSeconds != nil
    }

    func schedulePause(minutes: Int) {
        guard snapshot.isTracking else {
            cancelScheduledPause()
            return
        }

        let clampedMinutes = min(max(minutes, 1), 9)
        scheduledPauseTask?.cancel()
        let totalSeconds = clampedMinutes * 60
        scheduledPauseRemainingSeconds = totalSeconds

        scheduledPauseTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var remainingSeconds = totalSeconds
            while remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled {
                    return
                }
                remainingSeconds -= 1
                self.scheduledPauseRemainingSeconds = remainingSeconds
            }

            self.scheduledPauseRemainingSeconds = nil
            self.scheduledPauseTask = nil

            if !self.snapshot.isTracking {
                self.refresh()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            guard self.snapshot.isTracking else {
                return
            }

            self.controlService.toggleTracking(allowLaunchIfNeeded: false)
            self.refreshAfterUserAction()
        }
    }

    func cancelScheduledPause() {
        scheduledPauseTask?.cancel()
        scheduledPauseTask = nil
        scheduledPauseRemainingSeconds = nil
    }

    func refresh(forceReload: Bool = false) {
        guard !isRefreshing else {
            pendingRefresh = true
            pendingForceRefresh = pendingForceRefresh || forceReload
            return
        }

        isRefreshing = true
        let previousWasTracking = snapshot.isTracking

        Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.isRefreshing = false
                if self.pendingRefresh {
                    let shouldForceReload = self.pendingForceRefresh
                    self.pendingRefresh = false
                    self.pendingForceRefresh = false
                    self.refresh(forceReload: shouldForceReload)
                }
            }

            do {
                let latest = try await Task.detached(priority: .utility) {
                    if forceReload {
                        MonitaskReader.invalidateCaches()
                    }
                    return try MonitaskReader().loadSnapshot()
                }.value

                self.snapshot = latest
                if !latest.isTracking, self.hasScheduledPause {
                    self.cancelScheduledPause()
                }
                self.reconcileDisplayedCounter(previousWasTracking: previousWasTracking, authoritativeTotal: latest.totalSeconds)
                self.configureLocalTickerTimerIfNeeded()
                self.updateCounterPresentation()

                self.reminderManager.updateTrackingState(self.snapshot.isTracking)
                self.autoPauseManager.evaluate(snapshot: self.snapshot, controlService: self.controlService) { [weak self] in
                    self?.resumeTrackingFromAutoPausePopup()
                }
                self.loadError = nil
            } catch {
                self.loadError = "Unable to read Monitask data."
            }
        }
    }

    func refreshAfterUserAction() {
        actionRefreshTask?.cancel()
        actionRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let delays: [UInt64] = [0, 350_000_000, 900_000_000, 1_500_000_000, 2_500_000_000, 4_000_000_000, 7_000_000_000, 11_000_000_000]
            for delay in delays {
                if Task.isCancelled {
                    return
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                if Task.isCancelled {
                    return
                }
                self.refresh(forceReload: true)
                self.controlService.refreshReadiness()
            }

            self.actionRefreshTask = nil
        }
    }

    private func reconcileDisplayedCounter(previousWasTracking: Bool, authoritativeTotal: Int) {
        switch counterUpdateMethod {
        case .authoritative:
            displayedTotalSeconds = authoritativeTotal
        case .localTicker:
            guard snapshot.isTracking else {
                displayedTotalSeconds = authoritativeTotal
                return
            }

            if !previousWasTracking {
                displayedTotalSeconds = authoritativeTotal
                return
            }

            let drift = authoritativeTotal - displayedTotalSeconds
            if abs(drift) > Self.localTickerDriftSnapThreshold || displayedTotalSeconds < authoritativeTotal {
                displayedTotalSeconds = authoritativeTotal
            }
        }
    }

    private func applyCounterUpdateMethodChange() {
        switch counterUpdateMethod {
        case .authoritative:
            displayedTotalSeconds = snapshot.totalSeconds
        case .localTicker:
            displayedTotalSeconds = snapshot.totalSeconds
        }

        configureLocalTickerTimerIfNeeded()
        updateCounterPresentation()
    }

    func format(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let h = String(format: "%02d", min(hours, 99))
        let m = String(format: "%02d", minutes)
        return "\(h)h\u{2006}\(m)m"
    }

    func formatForCounter(seconds: Int) -> String {
        switch counterDisplayFormat {
        case .hoursMinutes:
            return format(seconds: seconds)
        case .hoursMinutesSeconds:
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let secondsPart = seconds % 60
            let h = String(format: "%02d", min(hours, 99))
            let m = String(format: "%02d", minutes)
            let s = String(format: "%02d", secondsPart)
            return "\(h)h\u{2006}\(m)m\u{2006}\(s)s"
        }
    }

    func formatForFloatingCounter(seconds: Int) -> String {
        switch counterDisplayFormat {
        case .hoursMinutes:
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let h = String(format: "%02d", min(hours, 99))
            let m = String(format: "%02d", minutes)
            return "\(h)h\u{2009}\(m)m"
        case .hoursMinutesSeconds:
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            let secondsPart = seconds % 60
            let h = String(format: "%02d", min(hours, 99))
            let m = String(format: "%02d", minutes)
            let s = String(format: "%02d", secondsPart)
            return "\(h)h\u{2009}\(m)m\u{2009}\(s)s"
        }
    }

    func resetToDefaults() {
        counterDisplayFormat = .hoursMinutes
        counterUpdateMethod = .authoritative
        refreshInterval = .oneSecond
        refresh()
    }

    func diagnosticsText(reminderManager: ReminderManager) -> String {
        let reminderEnabledText = reminderManager.isEnabled ? "yes" : "no"
        return [
            "Time: \(menuBarTitle)",
            "Status: \(statusText)",
            "Project: \(snapshot.selectedProjectName)",
            "Last Updated: \(lastUpdatedText)",
            "Counter Format: \(counterDisplayFormat.label)",
            "Counter Update: \(counterUpdateMethod.label)",
            "Sync Interval: \(refreshInterval.label)",
            "Reminder Enabled: \(reminderEnabledText)",
            "Reminder Grace: \(reminderManager.gracePeriodMinutes)m",
            "Reminder Cooldown: \(reminderManager.reminderCooldownMinutes)m",
            "Active Threshold: \(reminderManager.activityIdleThresholdSeconds)s"
        ].joined(separator: "\n")
    }

    private func updateCounterPresentation() {
        menuBarLabelImage = MenuBarLabelFactory.makeLabel(
            timeText: menuBarTitle,
            isTracking: snapshot.isTracking,
            showSeconds: counterDisplayFormat == .hoursMinutesSeconds
        )
        floatingCounterManager.update(
            title: floatingCounterTitle,
            isTracking: snapshot.isTracking,
            showSeconds: counterDisplayFormat == .hoursMinutesSeconds
        )
    }

    private func resumeTrackingFromAutoPausePopup() {
        let shouldLaunchAndStart = controlService.readiness == .monitaskNotRunning
        controlService.toggleTracking(allowLaunchIfNeeded: shouldLaunchAndStart)
        refreshAfterUserAction()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}
