import Foundation
import UserNotifications
import CoreGraphics
import Combine

final class ReminderManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var snoozeUntil: Date?
    @Published var gracePeriodMinutes: Int {
        didSet {
            UserDefaults.standard.set(gracePeriodMinutes, forKey: gracePeriodMinutesKey)
        }
    }
    @Published var reminderCooldownMinutes: Int {
        didSet {
            UserDefaults.standard.set(reminderCooldownMinutes, forKey: reminderCooldownMinutesKey)
        }
    }
    @Published var activityIdleThresholdSeconds: Int {
        didSet {
            UserDefaults.standard.set(activityIdleThresholdSeconds, forKey: activityIdleThresholdSecondsKey)
        }
    }

    private let center: UNUserNotificationCenter?
    private var timer: Timer?
    private var isTracking = false
    private var activeButNotTrackingSince: Date?
    private var lastReminderDate: Date?

    private let enabledKey = "reminder.enabled"
    private let snoozeUntilKey = "reminder.snoozeUntil"
    private let gracePeriodMinutesKey = "reminder.gracePeriodMinutes"
    private let reminderCooldownMinutesKey = "reminder.cooldownMinutes"
    private let activityIdleThresholdSecondsKey = "reminder.activityIdleThresholdSeconds"

    private let categoryIdentifier = "monitask.reminder"
    private let actionSnooze15 = "snooze.15"
    private let actionSnooze30 = "snooze.30"
    private let actionSnooze60 = "snooze.60"
    private let actionDisable = "disable"

    override init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: enabledKey)
        snoozeUntil = defaults.object(forKey: snoozeUntilKey) as? Date
        let storedGracePeriodMinutes = defaults.integer(forKey: gracePeriodMinutesKey)
        gracePeriodMinutes = storedGracePeriodMinutes == 0 ? 10 : storedGracePeriodMinutes
        let storedCooldownMinutes = defaults.integer(forKey: reminderCooldownMinutesKey)
        reminderCooldownMinutes = storedCooldownMinutes == 0 ? 10 : storedCooldownMinutes
        let storedIdleThresholdSeconds = defaults.integer(forKey: activityIdleThresholdSecondsKey)
        activityIdleThresholdSeconds = storedIdleThresholdSeconds == 0 ? 90 : storedIdleThresholdSeconds
        center = Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
        super.init()

        configureNotificationSupport()
        startTimer()
    }

    func updateTrackingState(_ isTracking: Bool) {
        self.isTracking = isTracking
        if isTracking {
            activeButNotTrackingSince = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard let center else {
                isEnabled = false
                UserDefaults.standard.set(false, forKey: enabledKey)
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { [weak self, enabledKey = self.enabledKey] granted, _ in
                guard let self else {
                    return
                }
                self.isEnabled = granted
                UserDefaults.standard.set(granted, forKey: enabledKey)
            }
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: enabledKey)
            activeButNotTrackingSince = nil
        }
    }

    func resetToDefaults() {
        setEnabled(false)
        snoozeUntil = nil
        UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
        gracePeriodMinutes = 10
        reminderCooldownMinutes = 10
        activityIdleThresholdSeconds = 90
        lastReminderDate = nil
        activeButNotTrackingSince = nil
    }

    func snooze(minutes: Int) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        snoozeUntil = until
        UserDefaults.standard.set(until, forKey: snoozeUntilKey)
        activeButNotTrackingSince = nil
    }

    var snoozeText: String? {
        guard let snoozeUntil else {
            return nil
        }
        let remaining = Int(max(0, snoozeUntil.timeIntervalSinceNow))
        if remaining <= 0 {
            return nil
        }
        return "Snoozed for \(remaining / 60)m"
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkReminderCondition()
        }
        timer?.tolerance = 2
    }

    private func checkReminderCondition(now: Date = Date()) {
        guard isEnabled else {
            return
        }
        if let snoozeUntil, now < snoozeUntil {
            return
        }
        if let snoozeUntil, now >= snoozeUntil {
            self.snoozeUntil = nil
            UserDefaults.standard.removeObject(forKey: snoozeUntilKey)
        }
        guard !isTracking else {
            activeButNotTrackingSince = nil
            return
        }

        let keyboardIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouseIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let clickIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let idleSeconds = min(keyboardIdle, mouseIdle, clickIdle)
        guard idleSeconds < TimeInterval(activityIdleThresholdSeconds) else {
            activeButNotTrackingSince = nil
            return
        }

        if activeButNotTrackingSince == nil {
            activeButNotTrackingSince = now
            return
        }

        guard let activeButNotTrackingSince else {
            return
        }

        if now.timeIntervalSince(activeButNotTrackingSince) >= TimeInterval(gracePeriodMinutes * 60) {
            if let lastReminderDate,
               now.timeIntervalSince(lastReminderDate) < TimeInterval(reminderCooldownMinutes * 60) {
                return
            }
            sendReminderNotification()
            lastReminderDate = now
        }
    }

    private func configureNotificationSupport() {
        guard let center else {
            return
        }
        center.delegate = self

        let snooze15 = UNNotificationAction(identifier: actionSnooze15, title: "Snooze 15m")
        let snooze30 = UNNotificationAction(identifier: actionSnooze30, title: "Snooze 30m")
        let snooze60 = UNNotificationAction(identifier: actionSnooze60, title: "Snooze 60m")
        let disable = UNNotificationAction(identifier: actionDisable, title: "Disable Reminder")
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [snooze15, snooze30, snooze60, disable],
            intentIdentifiers: []
        )

        center.setNotificationCategories([category])
    }

    private func sendReminderNotification() {
        guard let center else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Monitask is not tracking"
        content.body = "You are active on your Mac, but Monitask appears stopped."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        let request = UNNotificationRequest(
            identifier: "monitask-reminder-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case actionSnooze15:
            snooze(minutes: 15)
        case actionSnooze30:
            snooze(minutes: 30)
        case actionSnooze60:
            snooze(minutes: 60)
        case actionDisable:
            setEnabled(false)
        default:
            break
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
