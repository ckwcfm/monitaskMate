import AppKit
import SwiftUI

@MainActor
final class IdlePausePopupManager: NSObject, ObservableObject {
    private let state = IdlePausePopupState()
    private var panel: NSPanel?

    func showPausedMessage(idleMinutes: Int, onResume: @escaping () -> Void) {
        state.idleMinutes = max(1, idleMinutes)
        state.onResume = { [weak self] in
            self?.hide()
            onResume()
        }
        state.onDismiss = { [weak self] in
            self?.hide()
        }

        if panel == nil {
            panel = makePanel()
        }

        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 148),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "MonitaskMate"
        panel.titlebarAppearsTransparent = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: IdlePausePopupView(state: state))
        return panel
    }
}

@MainActor
private final class IdlePausePopupState: ObservableObject {
    @Published var idleMinutes: Int = 1
    var onResume: (() -> Void)?
    var onDismiss: (() -> Void)?

    var titleText: String {
        "Tracking paused due to inactivity - \(idleMinutes) min"
    }
}

private struct IdlePausePopupView: View {
    @ObservedObject var state: IdlePausePopupState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Image(nsImage: NSWorkspace.shared.icon(forFile: "/Applications/Monitask.app"))
                    .resizable()
                    .frame(width: 20, height: 20)
                Spacer(minLength: 2)
            }

            Text(state.titleText)
                .font(.title3)
                .fontWeight(.semibold)

            HStack {
                Spacer()
                Button("Dismiss") {
                    state.onDismiss?()
                }
                Button("Resume Tracking") {
                    state.onResume?()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
