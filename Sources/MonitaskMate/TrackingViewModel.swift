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
        selectedProjectName: "Loading",
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

    private let reader = MonitaskReader()
    private let reminderManager: ReminderManager
    private let floatingCounterManager: FloatingCounterManager
    private var refreshTimer: Timer?
    private var localTickerTimer: Timer?
    private var displayedTotalSeconds = 0

    private static let refreshIntervalKey = "tracking.refreshIntervalSeconds"
    private static let counterDisplayFormatKey = "tracking.counterDisplayFormat"
    private static let counterUpdateMethodKey = "tracking.counterUpdateMethod"
    private static let localTickerDriftSnapThreshold = 2

    init(reminderManager: ReminderManager, floatingCounterManager: FloatingCounterManager) {
        self.reminderManager = reminderManager
        self.floatingCounterManager = floatingCounterManager
        menuBarLabelImage = MenuBarLabelFactory.makeLabel(timeText: "00h 00m", isTracking: false, showSeconds: false)

        let storedDisplayFormat = UserDefaults.standard.string(forKey: Self.counterDisplayFormatKey)
        counterDisplayFormat = CounterDisplayFormat(rawValue: storedDisplayFormat ?? "") ?? .hoursMinutes

        let storedUpdateMethod = UserDefaults.standard.string(forKey: Self.counterUpdateMethodKey)
        counterUpdateMethod = CounterUpdateMethod(rawValue: storedUpdateMethod ?? "") ?? .authoritative

        let stored = UserDefaults.standard.integer(forKey: Self.refreshIntervalKey)
        refreshInterval = RefreshInterval(rawValue: stored) ?? .oneSecond

        refresh()
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

    func refresh() {
        do {
            let previousWasTracking = snapshot.isTracking
            let latest = try reader.loadSnapshot()
            snapshot = latest

            reconcileDisplayedCounter(previousWasTracking: previousWasTracking, authoritativeTotal: latest.totalSeconds)
            configureLocalTickerTimerIfNeeded()
            updateCounterPresentation()

            reminderManager.updateTrackingState(snapshot.isTracking)
            loadError = nil
        } catch {
            loadError = "Unable to read Monitask data."
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}
