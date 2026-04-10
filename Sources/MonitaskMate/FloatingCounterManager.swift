import AppKit
import SwiftUI

@MainActor
final class FloatingCounterManager: NSObject, ObservableObject, NSWindowDelegate {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                showPanel()
            } else {
                hidePanel()
            }
        }
    }

    @Published var opacity: Double {
        didSet {
            let clamped = min(max(opacity, 0.3), 1.0)
            UserDefaults.standard.set(clamped, forKey: Self.opacityKey)
            DispatchQueue.main.async { [weak self] in
                self?.state.opacity = clamped
            }
        }
    }

    private let state = FloatingCounterState()
    private var panel: NSPanel?

    private static let enabledKey = "floatingCounter.enabled"
    private static let opacityKey = "floatingCounter.opacity"
    private static let positionXKey = "floatingCounter.positionX"
    private static let positionYKey = "floatingCounter.positionY"

    override init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let storedOpacity = defaults.object(forKey: Self.opacityKey) as? Double
        opacity = min(max(storedOpacity ?? 0.92, 0.3), 1.0)
        super.init()
        state.opacity = opacity

        if isEnabled {
            showPanel()

        }
    }

    func update(title: String, isTracking: Bool, showSeconds: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyUpdate(title: title, isTracking: isTracking, showSeconds: showSeconds)
        }
    }

    private func applyUpdate(title: String, isTracking: Bool, showSeconds: Bool) {
        state.title = title
        state.isTracking = isTracking
        state.showSeconds = showSeconds

        if let panel {
            let nextSize = panelSize(showSeconds: showSeconds)
            if panel.contentRect(forFrameRect: panel.frame).size != nextSize {
                panel.setContentSize(nextSize)
            }
        }

        if isEnabled {
            showPanel()
        }
    }

    func resetToDefaults() {
        isEnabled = false
        opacity = 0.92
    }

    private func showPanel() {
        if panel == nil {
            panel = makePanel()
        }
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panelSize = panelSize(showSeconds: state.showSeconds)
        let panel = NSPanel(
            contentRect: NSRect(origin: restoredOrigin(for: panelSize), size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self

        panel.contentView = NSHostingView(rootView: FloatingCounterView(state: state))
        return panel
    }

    private func panelSize(showSeconds: Bool) -> NSSize {
        NSSize(width: showSeconds ? 162 : 134, height: 38)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        UserDefaults.standard.set(window.frame.origin.x, forKey: Self.positionXKey)
        UserDefaults.standard.set(window.frame.origin.y, forKey: Self.positionYKey)
    }

    private func restoredOrigin(for size: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.positionXKey) != nil,
           defaults.object(forKey: Self.positionYKey) != nil {
            let x = defaults.double(forKey: Self.positionXKey)
            let y = defaults.double(forKey: Self.positionYKey)
            return NSPoint(x: x, y: y)
        }

        if let visibleFrame = NSScreen.main?.visibleFrame {
            return NSPoint(
                x: visibleFrame.maxX - size.width - 24,
                y: visibleFrame.minY + 24
            )
        }
        return NSPoint(x: 120, y: 120)
    }
}

@MainActor
private final class FloatingCounterState: ObservableObject {
    @Published var title: String = "0h 00m"
    @Published var isTracking: Bool = false
    @Published var opacity: Double = 0.92
    @Published var showSeconds: Bool = false
    let appIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(forFile: "/Applications/Monitask.app")
        icon.size = NSSize(width: 14, height: 14)
        icon.isTemplate = false
        return icon
    }()
}

private struct FloatingCounterView: View {
    @ObservedObject var state: FloatingCounterState

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: MenuBarIconFactory.makeIcon(isTracking: state.isTracking))
                .resizable()
                .frame(width: 16, height: 16)

            Text(state.title)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .frame(width: state.showSeconds ? 94 : 68, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        }
        .opacity(state.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }
}
