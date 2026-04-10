import Foundation
import AppKit
import ApplicationServices

@MainActor
final class MonitaskControlService: ObservableObject {
    enum Readiness: Equatable {
        case ready
        case monitaskNotInstalled
        case accessibilityPermissionRequired
        case monitaskNotRunning
        case controlNotFound
        case failed(String)

        var label: String {
            switch self {
            case .ready:
                return "Ready"
            case .monitaskNotInstalled:
                return "Monitask Not Installed"
            case .accessibilityPermissionRequired:
                return "Needs Accessibility"
            case .monitaskNotRunning:
                return "Monitask Not Running"
            case .controlNotFound:
                return "Toggle Control Not Found"
            case .failed(let message):
                return message
            }
        }

        var isReady: Bool {
            if case .ready = self {
                return true
            }
            return false
        }
    }

    @Published private(set) var readiness: Readiness = .monitaskNotRunning
    @Published private(set) var lastActionStatus: String?
    @Published private(set) var isMonitaskInstalled: Bool = true

    private let bundleIdentifier = "com.seleike.Monitask-Client-MacOS"
    private var permissionPollTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var launchRetryTask: Task<Void, Never>?

    func refreshReadiness() {
        refreshInstallationState()
        guard isMonitaskInstalled else {
            readiness = .monitaskNotInstalled
            return
        }

        guard isAccessibilityGranted() else {
            readiness = .accessibilityPermissionRequired
            return
        }

        guard let appElement = monitaskAppElement() else {
            readiness = .monitaskNotRunning
            return
        }

        if findToggleElement(in: appElement) != nil {
            readiness = .ready
        } else {
            readiness = .controlNotFound
        }
    }

    func requestAccessibilityPermissionPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPermissionPolling()
        refreshReadiness()
    }

    func toggleTracking(allowLaunchIfNeeded: Bool = false) {
        refreshInstallationState()
        guard isMonitaskInstalled else {
            readiness = .monitaskNotInstalled
            lastActionStatus = "Monitask app is not installed."
            return
        }

        guard isAccessibilityGranted() else {
            readiness = .accessibilityPermissionRequired
            lastActionStatus = "Enable Accessibility for MonitaskMate first."
            return
        }

        guard let appElement = monitaskAppElement() else {
            if allowLaunchIfNeeded {
                launchMonitaskAndRetryToggle()
                return
            }
            readiness = .monitaskNotRunning
            lastActionStatus = "Monitask app is not running."
            return
        }

        guard let target = findToggleElement(in: appElement) else {
            readiness = .controlNotFound
            lastActionStatus = "Unable to locate Monitask toggle control."
            return
        }

        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if result == .success {
            readiness = .ready
            setTransientStatus("Toggle sent to Monitask.")
        } else {
            readiness = .failed("Toggle failed (\(result.rawValue)).")
            lastActionStatus = "Failed to toggle tracking."
        }
    }

    private func setTransientStatus(_ message: String) {
        statusClearTask?.cancel()
        lastActionStatus = message
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            self.lastActionStatus = nil
            self.statusClearTask = nil
        }
    }

    private func launchMonitaskAndRetryToggle() {
        launchRetryTask?.cancel()

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            isMonitaskInstalled = false
            readiness = .monitaskNotInstalled
            lastActionStatus = "Monitask app is not installed."
            return
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }

                if error != nil {
                    self.readiness = .monitaskNotRunning
                    self.lastActionStatus = "Unable to launch Monitask."
                    return
                }

                self.setTransientStatus("Launching Monitask...")
                self.retryToggleAfterLaunch(attemptsRemaining: 14)
            }
        }
    }

    private func retryToggleAfterLaunch(attemptsRemaining: Int) {
        launchRetryTask?.cancel()
        launchRetryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for _ in 0..<attemptsRemaining {
                if Task.isCancelled {
                    self.launchRetryTask = nil
                    return
                }

                self.refreshReadiness()

                if let appElement = self.monitaskAppElement(),
                   let target = self.findToggleElement(in: appElement) {
                    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
                    self.launchRetryTask = nil

                    if result == .success {
                        self.readiness = .ready
                        self.setTransientStatus("Monitask launched and tracking started.")
                    } else {
                        self.readiness = .failed("Toggle failed (\(result.rawValue)).")
                        self.lastActionStatus = "Launched Monitask, but failed to start tracking."
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            self.lastActionStatus = "Monitask opened, but toggle not ready yet."
            self.launchRetryTask = nil
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func isAccessibilityGranted() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for _ in 0..<15 {
                if Task.isCancelled {
                    self.permissionPollTask = nil
                    return
                }

                self.refreshReadiness()
                if self.readiness != .accessibilityPermissionRequired {
                    self.permissionPollTask = nil
                    return
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            self.permissionPollTask = nil
        }
    }

    private func monitaskAppElement() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func refreshInstallationState() {
        isMonitaskInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    private struct Candidate {
        let element: AXUIElement
        let role: String
        let title: String
        let description: String
        let isEnabled: Bool
        let frame: CGRect
        let value: Int?
        let actions: [String]
    }

    private func findToggleElement(in appElement: AXUIElement) -> AXUIElement? {
        let allElements = gatherElements(in: appElement)
        guard !allElements.isEmpty else {
            return nil
        }

        let timerFrame = allElements
            .filter { $0.role == kAXStaticTextRole as String }
            .first { $0.title.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil }?
            .frame

        let candidates = allElements.filter {
            ($0.role == kAXCheckBoxRole as String || $0.role == kAXButtonRole as String)
            && $0.actions.contains(kAXPressAction as String)
        }

        guard !candidates.isEmpty else {
            return nil
        }

        let enabledCandidates = candidates.filter { $0.isEnabled }
        let source = enabledCandidates.isEmpty ? candidates : enabledCandidates

        let best = source.max { lhs, rhs in
            score(lhs, timerFrame: timerFrame) < score(rhs, timerFrame: timerFrame)
        }

        return best?.element
    }

    private func score(_ candidate: Candidate, timerFrame: CGRect?) -> Int {
        var total = 0

        if candidate.role == kAXCheckBoxRole as String {
            total += 200
        }

        if candidate.frame.width >= 36, candidate.frame.width <= 74,
           candidate.frame.height >= 36, candidate.frame.height <= 58 {
            total += 120
        }

        if candidate.title == "Add" || candidate.description.lowercased().contains("refresh") {
            total -= 500
        }

        if let timerFrame {
            let timerMidY = timerFrame.midY
            let candidateMidY = candidate.frame.midY
            let verticalDistance = abs(candidateMidY - timerMidY)
            if verticalDistance < 120 {
                total += 100
            }
            if candidate.frame.midX < timerFrame.midX {
                total += 80
            }
            if candidate.frame.maxX <= timerFrame.minX + 8 {
                total += 40
            }
        }

        if let value = candidate.value {
            if value == 0 || value == 1 {
                total += 20
            }
        }

        return total
    }

    private func gatherElements(in appElement: AXUIElement) -> [Candidate] {
        var result: [Candidate] = []
        var queue: [AXUIElement] = [appElement]
        var visited = Set<String>()

        while let current = queue.popLast() {
            let id = "\(Unmanaged.passUnretained(current).toOpaque())"
            if visited.contains(id) { continue }
            visited.insert(id)

            if let candidate = candidate(from: current) {
                result.append(candidate)
            }

            if let children = copyElementsAttribute(current, attribute: kAXChildrenAttribute as CFString) {
                queue.append(contentsOf: children)
            }
            if let windows = copyElementsAttribute(current, attribute: kAXWindowsAttribute as CFString) {
                queue.append(contentsOf: windows)
            }
        }

        return result
    }

    private func candidate(from element: AXUIElement) -> Candidate? {
        guard let role = copyStringAttribute(element, attribute: kAXRoleAttribute as CFString) else {
            return nil
        }

        let title = copyStringAttribute(element, attribute: kAXTitleAttribute as CFString) ?? ""
        let description = copyStringAttribute(element, attribute: kAXDescriptionAttribute as CFString) ?? ""
        let isEnabled = copyBoolAttribute(element, attribute: kAXEnabledAttribute as CFString) ?? true
        let actions = copyActionNames(element)
        let value = copyIntAttribute(element, attribute: kAXValueAttribute as CFString)

        guard let frame = frame(of: element) else {
            return Candidate(
                element: element,
                role: role,
                title: title,
                description: description,
                isEnabled: isEnabled,
                frame: .zero,
                value: value,
                actions: actions
            )
        }

        return Candidate(
            element: element,
            role: role,
            title: title,
            description: description,
            isEnabled: isEnabled,
            frame: frame,
            value: value,
            actions: actions
        )
    }

    private func copyElementsAttribute(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let array = value as? [AXUIElement] else {
            return nil
        }
        return array
    }

    private func copyStringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyIntAttribute(_ element: AXUIElement, attribute: CFString) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func copyBoolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func copyActionNames(_ element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let actions = value as? [String] else {
            return []
        }
        return actions
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copyPointAttribute(element, attribute: kAXPositionAttribute as CFString),
              let size = copySizeAttribute(element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func copyPointAttribute(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func copySizeAttribute(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
