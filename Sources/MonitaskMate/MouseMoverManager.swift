import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class MouseMoverManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var hasAccessibilityPermission: Bool

    private let enabledKey = "mouseMover.enabled"
    private let interval: TimeInterval = 3
    private var direction: CGFloat = 1
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSessionActive = true
    private var isScreenAwake = true

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        hasAccessibilityPermission = AXIsProcessTrusted()
        observeWorkspaceState()
        updateTimer()
    }

    deinit {
        timer?.invalidate()
        permissionTimer?.invalidate()
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)

        if enabled && !hasAccessibilityPermission {
            requestAccessibilityPermission()
        }
        updateTimer()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAccessibilityPermission()

        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityPermission()
            }
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func resetToDefaults() {
        setEnabled(false)
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil

        guard isEnabled, hasAccessibilityPermission, isSessionActive, isScreenAwake else {
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.moveCursor()
            }
        }
        timer?.tolerance = 0.1
    }

    private func moveCursor() {
        guard AXIsProcessTrusted(), let currentLocation = CGEvent(source: nil)?.location else {
            refreshAccessibilityPermission()
            return
        }

        let targetLocation = CGPoint(x: currentLocation.x + direction, y: currentLocation.y)
        direction *= -1

        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: targetLocation,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    private func refreshAccessibilityPermission() {
        let granted = AXIsProcessTrusted()
        guard granted != hasAccessibilityPermission else {
            return
        }

        hasAccessibilityPermission = granted
        if granted {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
        updateTimer()
    }

    private func observeWorkspaceState() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isSessionActive = false
                    self?.updateTimer()
                }
            },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isSessionActive = true
                    self?.refreshAccessibilityPermission()
                    self?.updateTimer()
                }
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isScreenAwake = false
                    self?.updateTimer()
                }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isScreenAwake = true
                    self?.updateTimer()
                }
            }
        ]
    }
}
