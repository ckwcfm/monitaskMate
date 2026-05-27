import Foundation
import OSLog

@MainActor
final class AutoPauseManager: ObservableObject {
    static let thresholdOptionsMinutes = [3, 5, 7, 9, 10]

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                resetSessionPauseTracking()
                popupManager.hide()
            }
        }
    }

    @Published var idleThresholdMinutes: Int {
        didSet {
            let normalized = Self.thresholdOptionsMinutes.contains(idleThresholdMinutes) ? idleThresholdMinutes : Self.defaultThresholdMinutes
            if normalized != idleThresholdMinutes {
                idleThresholdMinutes = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: Self.thresholdMinutesKey)
        }
    }

    @Published var showsTopPopup: Bool {
        didSet {
            UserDefaults.standard.set(showsTopPopup, forKey: Self.showPopupKey)
            if !showsTopPopup {
                popupManager.hide()
            }
        }
    }

    private let popupManager: IdlePausePopupManager
    private let logger = Logger(subsystem: "MonitaskMate", category: "AutoPause")
    private var hasAutoPausedCurrentIdleEpisode = false
    private var lastAutoPauseAt: Date?
    private var awaitingPauseConfirmation = false
    private var pendingPopupIdleMinutes: Int?

    private static let enabledKey = "autoPause.enabled"
    private static let thresholdMinutesKey = "autoPause.idleThresholdMinutes"
    private static let showPopupKey = "autoPause.showTopPopup"
    private static let defaultThresholdMinutes = 9
    private static let pauseCooldownSeconds: TimeInterval = 45

    init(popupManager: IdlePausePopupManager) {
        self.popupManager = popupManager

        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)

        let storedMinutes = defaults.integer(forKey: Self.thresholdMinutesKey)
        if Self.thresholdOptionsMinutes.contains(storedMinutes) {
            idleThresholdMinutes = storedMinutes
        } else {
            idleThresholdMinutes = Self.defaultThresholdMinutes
        }

        if defaults.object(forKey: Self.showPopupKey) == nil {
            showsTopPopup = true
        } else {
            showsTopPopup = defaults.bool(forKey: Self.showPopupKey)
        }
    }

    func evaluate(snapshot: TrackingSnapshot, controlService: MonitaskControlService, onResumeRequested: @escaping () -> Void) {
        guard isEnabled else {
            resetSessionPauseTracking()
            return
        }

        if awaitingPauseConfirmation {
            if !snapshot.isTracking {
                logger.debug("Auto pause confirmed. idleMinutes=\(self.pendingPopupIdleMinutes ?? 0)")
                awaitingPauseConfirmation = false
                if showsTopPopup, let idleMinutes = pendingPopupIdleMinutes {
                    popupManager.showPausedMessage(idleMinutes: idleMinutes, onResume: onResumeRequested)
                }
                pendingPopupIdleMinutes = nil
                return
            }

            if let lastAutoPauseAt,
               Date().timeIntervalSince(lastAutoPauseAt) > 8 {
                logger.warning("Auto pause confirmation timed out; resetting idle episode")
                awaitingPauseConfirmation = false
                pendingPopupIdleMinutes = nil
                hasAutoPausedCurrentIdleEpisode = false
            }
            return
        }

        guard snapshot.isTracking else {
            resetSessionPauseTracking()
            return
        }

        guard let lastActiveAt = snapshot.lastActiveAt else {
            return
        }

        let now = Date()
        let idleSeconds = now.timeIntervalSince(lastActiveAt)
        let thresholdSeconds = TimeInterval(idleThresholdMinutes * 60)

        if idleSeconds < thresholdSeconds {
            resetSessionPauseTracking()
            return
        }

        if hasAutoPausedCurrentIdleEpisode {
            return
        }

        if let lastAutoPauseAt,
           now.timeIntervalSince(lastAutoPauseAt) < Self.pauseCooldownSeconds {
            logger.debug("Auto pause suppressed by cooldown")
            return
        }

        hasAutoPausedCurrentIdleEpisode = true
        self.lastAutoPauseAt = now
        awaitingPauseConfirmation = true
        pendingPopupIdleMinutes = max(1, Int(idleSeconds / 60))
        logger.notice("Triggering auto pause. idleSeconds=\(Int(idleSeconds)) thresholdSeconds=\(Int(thresholdSeconds))")

        controlService.toggleTracking(allowLaunchIfNeeded: false)
    }

    func resetToDefaults() {
        isEnabled = false
        idleThresholdMinutes = Self.defaultThresholdMinutes
        showsTopPopup = true
        resetSessionPauseTracking()
        popupManager.hide()
    }

    private func resetSessionPauseTracking() {
        hasAutoPausedCurrentIdleEpisode = false
        awaitingPauseConfirmation = false
        pendingPopupIdleMinutes = nil
    }
}
