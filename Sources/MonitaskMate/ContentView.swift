import SwiftUI
import AppKit

struct ContentView: View {
    private enum SectionItem: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview:
                return "clock"
            case .settings:
                return "gearshape"
            }
        }
    }

    @ObservedObject var viewModel: TrackingViewModel
    @ObservedObject var reminderManager: ReminderManager
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @ObservedObject var floatingCounterManager: FloatingCounterManager
    @ObservedObject var controlService: MonitaskControlService
    @ObservedObject var autoPauseManager: AutoPauseManager
    @State private var selectedSection: SectionItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SectionItem.allCases, selection: $selectedSection) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .padding(.top, 8)
            .frame(maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 140, ideal: 170)
        } detail: {
            Group {
                switch selectedSection ?? .overview {
                case .overview:
                    overviewTab
                case .settings:
                    SettingsView(
                        viewModel: viewModel,
                        reminderManager: reminderManager,
                        launchAtLoginManager: launchAtLoginManager,
                        floatingCounterManager: floatingCounterManager,
                        controlService: controlService,
                        autoPauseManager: autoPauseManager
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 8)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var overviewTab: some View {
        if !controlService.isMonitaskInstalled {
            return AnyView(notInstalledView)
        }

        return AnyView(
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(viewModel.statusDot)
                        .font(.largeTitle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.statusText)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Project: \(viewModel.snapshot.selectedProjectName)")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    metric(title: "Total", value: viewModel.format(seconds: viewModel.snapshot.totalSeconds))
                    metric(title: "Current Session", value: viewModel.format(seconds: viewModel.snapshot.activeSeconds))
                    metric(title: "This Month", value: viewModel.monthlyTotalText)
                    metric(title: "Today Activity", value: viewModel.todayActivityText)
                    metric(title: "Reminder", value: reminderManager.isEnabled ? "On" : "Off")
                    if let snoozeText = reminderManager.snoozeText {
                        metric(title: "Snooze", value: snoozeText)
                    }
                    if let scheduledPauseText = viewModel.scheduledPauseText {
                        metric(title: "Scheduled Pause", value: scheduledPauseText)
                    }
                }

                if viewModel.hasScheduledPause {
                    Button("Cancel Scheduled Pause") {
                        viewModel.cancelScheduledPause()
                    }
                }

                if let loadError = viewModel.loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                }

                Spacer(minLength: 0)

                HStack {
                    Text("Updates every \(viewModel.refreshIntervalText)")
                        .foregroundStyle(.secondary)
                    Text("Last update: \(viewModel.lastUpdatedText)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") {
                        viewModel.refresh()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        )
    }

    private var notInstalledView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monitask Not Installed")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Install Monitask on this Mac to enable tracking, reminders, and controls in MonitaskMate.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func metric(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct MenuPanelView: View {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var viewModel: TrackingViewModel
    @ObservedObject var reminderManager: ReminderManager
    @ObservedObject var controlService: MonitaskControlService
    @ObservedObject var autoPauseManager: AutoPauseManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MonitaskMate")
                .font(.headline)

            if !controlService.isMonitaskInstalled {
                Text("Monitask Not Installed")
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)

                Text("Install Monitask to enable counter sync and control features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                Button("Preference") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.title == "MonitaskMate" })?.makeKeyAndOrderFront(nil)
                }
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            } else {
            Text("Status: \(viewModel.statusText)")
            Text("Total: \(viewModel.format(seconds: viewModel.snapshot.totalSeconds))")
            Text("This Month: \(viewModel.monthlyTotalText)")
            Text("Today Activity: \(viewModel.todayActivityText)")
            Text("Updated: \(viewModel.lastUpdatedText)")
                .foregroundStyle(.secondary)

            Picker("Sync Interval", selection: $viewModel.refreshInterval) {
                ForEach(TrackingViewModel.RefreshInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }
            .pickerStyle(.menu)

            Divider()
            Button(viewModel.snapshot.isTracking ? "Stop Tracking" : "Start Tracking") {
                let shouldLaunchAndStart = !viewModel.snapshot.isTracking && controlService.readiness == .monitaskNotRunning
                controlService.toggleTracking(allowLaunchIfNeeded: shouldLaunchAndStart)
                viewModel.refreshAfterUserAction()
            }
            .disabled(
                !controlService.isMonitaskInstalled
                || controlService.readiness == .accessibilityPermissionRequired
            )

            Menu("Schedule Pause") {
                ForEach(1...9, id: \.self) { minutes in
                    Button("In \(minutes)m") {
                        viewModel.schedulePause(minutes: minutes)
                    }
                }
            }
            .disabled(!viewModel.snapshot.isTracking)

            if let scheduledPauseText = viewModel.scheduledPauseText {
                Text(scheduledPauseText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel Scheduled Pause") {
                    viewModel.cancelScheduledPause()
                }
            }

            Button("Sync Now") {
                let shouldLaunchAndSync = controlService.readiness == .monitaskNotRunning
                controlService.triggerMonitaskRefresh(allowLaunchIfNeeded: shouldLaunchAndSync)
                viewModel.refreshAfterUserAction()
            }
            .disabled(
                !controlService.isMonitaskInstalled
                || controlService.readiness == .accessibilityPermissionRequired
            )

            if !controlService.readiness.isReady {
                Text(controlService.readiness.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controlService.readiness == .accessibilityPermissionRequired {
                Button("Enable Accessibility") {
                    controlService.requestAccessibilityPermissionPrompt()
                }
            }

            if let lastActionStatus = controlService.lastActionStatus {
                Text(lastActionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Auto Pause")
                .font(.subheadline)
                .fontWeight(.semibold)

            Toggle("Auto Pause", isOn: $autoPauseManager.isEnabled)

            Picker("Idle Threshold", selection: $autoPauseManager.idleThresholdMinutes) {
                ForEach(AutoPauseManager.thresholdOptionsMinutes, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.menu)
            .disabled(!autoPauseManager.isEnabled)

            Toggle("Top Popup", isOn: $autoPauseManager.showsTopPopup)
                .disabled(!autoPauseManager.isEnabled)

            Divider()
            Text("Reminder")
                .font(.subheadline)
                .fontWeight(.semibold)
            Toggle("Smart Reminder", isOn: Binding(
                get: { reminderManager.isEnabled },
                set: { reminderManager.setEnabled($0) }
            ))

            HStack {
                Text("Reminder Status:")
                    .foregroundStyle(.secondary)
                Text(reminderManager.isEnabled ? "ON" : "OFF")
                    .fontWeight(.semibold)
                    .foregroundStyle(reminderManager.isEnabled ? .green : .red)
            }

            if let snoozeText = reminderManager.snoozeText {
                Text(snoozeText)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("15m") {
                    reminderManager.snooze(minutes: 15)
                }
                Button("30m") {
                    reminderManager.snooze(minutes: 30)
                }
                Button("60m") {
                    reminderManager.snooze(minutes: 60)
                }
            }
            .disabled(!reminderManager.isEnabled)

            Divider()
            Button("Refresh") {
                viewModel.refresh()
                controlService.refreshReadiness()
            }
            Button("Preference") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.title == "MonitaskMate" })?.makeKeyAndOrderFront(nil)
            }
            Button("Quit") {
                NSApp.terminate(nil)
            }
            }
        }
        .padding(12)
        .frame(minWidth: 220)
        .onAppear {
            controlService.refreshReadiness()
        }
    }
}
