import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var viewModel: TrackingViewModel
    @ObservedObject var reminderManager: ReminderManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject var floatingCounterManager: FloatingCounterManager

    private let reminderMinuteOptions = [5, 10, 15, 20, 30]
    private let idleThresholdOptions = [30, 60, 90, 120, 180]

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "MonitaskMate v\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionCard("General") {
                    settingPicker(
                        title: "Sync Interval",
                        description: "How often MonitaskMate refreshes local tracking data.",
                        selection: $viewModel.refreshInterval
                    ) {
                        ForEach(TrackingViewModel.RefreshInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }

                    settingPicker(
                        title: "Counter Display Format",
                        description: "Choose whether the menu/floating counter includes seconds.",
                        selection: $viewModel.counterDisplayFormat
                    ) {
                        ForEach(TrackingViewModel.CounterDisplayFormat.allCases) { format in
                            Text(format.label).tag(format)
                        }
                    }

                    Text(viewModel.counterDisplayFormat.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    settingPicker(
                        title: "Counter Update Method",
                        description: "Choose whether the timer follows Monitask files exactly or increments locally while tracking.",
                        selection: $viewModel.counterUpdateMethod
                    ) {
                        ForEach(TrackingViewModel.CounterUpdateMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }

                    Text(viewModel.counterUpdateMethod.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )) {
                        settingTitleDescription(
                            title: "Launch at Login",
                            description: "Starts MonitaskMate automatically when you sign in."
                        )
                    }

                    Toggle(isOn: $floatingCounterManager.isEnabled) {
                        settingTitleDescription(
                            title: "Floating Counter",
                            description: "Shows an always-on-top mini timer window so you can monitor status when the menu bar is hidden behind the notch."
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        settingTitleDescription(
                            title: "Floating Counter Opacity",
                            description: "Adjusts transparency of the floating timer window."
                        )
                        Slider(value: $floatingCounterManager.opacity, in: 0.4...1.0, step: 0.05)
                    }
                    .disabled(!floatingCounterManager.isEnabled)

                    if let errorMessage = launchAtLoginManager.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                sectionCard("Reminder") {
                    Toggle(isOn: Binding(
                        get: { reminderManager.isEnabled },
                        set: { reminderManager.setEnabled($0) }
                    )) {
                        settingTitleDescription(
                            title: "Smart Reminder",
                            description: "Sends notifications when you are active on your Mac but Monitask is not tracking."
                        )
                    }

                    settingPicker(
                        title: "Reminder Delay",
                        description: "How long Monitask can stay off before the first reminder appears.",
                        selection: $reminderManager.gracePeriodMinutes
                    ) {
                        ForEach(reminderMinuteOptions, id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    .disabled(!reminderManager.isEnabled)

                    settingPicker(
                        title: "Reminder Cooldown",
                        description: "Minimum wait time between repeated reminders.",
                        selection: $reminderManager.reminderCooldownMinutes
                    ) {
                        ForEach(reminderMinuteOptions, id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                    .disabled(!reminderManager.isEnabled)

                    settingPicker(
                        title: "Active User Threshold",
                        description: "If idle time is below this value, you are treated as actively using the computer.",
                        selection: $reminderManager.activityIdleThresholdSeconds
                    ) {
                        ForEach(idleThresholdOptions, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .disabled(!reminderManager.isEnabled)
                }

                sectionCard("Diagnostics") {
                    Text("Last Update: \(viewModel.lastUpdatedText)")
                    Text("Status: \(viewModel.statusText)")
                    Text("Project: \(viewModel.snapshot.selectedProjectName)")

                    HStack {
                        Button("Refresh Now") {
                            viewModel.refresh()
                        }
                        Button("Copy Diagnostics") {
                            copyDiagnostics()
                        }
                    }
                }

                sectionCard("Danger Zone") {
                    Button("Reset Settings to Defaults") {
                        viewModel.resetToDefaults()
                        reminderManager.resetToDefaults()
                        launchAtLoginManager.setEnabled(false)
                        floatingCounterManager.resetToDefaults()
                    }
                }

                Text(appVersionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding(24)
        }
    }

    private func sectionCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.headline)
        }
    }

    private func settingTitleDescription(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func settingPicker<Selection: Hashable, Content: View>(
        title: String,
        description: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            settingTitleDescription(title: title, description: description)
            Picker("", selection: selection) {
                content()
            }
            .labelsHidden()
        }
    }

    private func copyDiagnostics() {
        let diagnostics = viewModel.diagnosticsText(reminderManager: reminderManager)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }
}
