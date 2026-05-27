import SwiftUI

@main
struct MonitaskMateApp: App {
    @StateObject private var viewModel: TrackingViewModel
    @StateObject private var reminderManager: ReminderManager
    @StateObject private var launchAtLoginManager: LaunchAtLoginManager
    @StateObject private var floatingCounterManager: FloatingCounterManager
    @StateObject private var controlService: MonitaskControlService
    @StateObject private var autoPauseManager: AutoPauseManager
    @StateObject private var idlePausePopupManager: IdlePausePopupManager

    init() {
        let reminderManager = ReminderManager()
        let launchAtLoginManager = LaunchAtLoginManager()
        let floatingCounterManager = FloatingCounterManager()
        let controlService = MonitaskControlService()
        let idlePausePopupManager = IdlePausePopupManager()
        let autoPauseManager = AutoPauseManager(popupManager: idlePausePopupManager)
        _reminderManager = StateObject(wrappedValue: reminderManager)
        _launchAtLoginManager = StateObject(wrappedValue: launchAtLoginManager)
        _floatingCounterManager = StateObject(wrappedValue: floatingCounterManager)
        _controlService = StateObject(wrappedValue: controlService)
        _idlePausePopupManager = StateObject(wrappedValue: idlePausePopupManager)
        _autoPauseManager = StateObject(wrappedValue: autoPauseManager)
        _viewModel = StateObject(
            wrappedValue: TrackingViewModel(
                reminderManager: reminderManager,
                floatingCounterManager: floatingCounterManager,
                autoPauseManager: autoPauseManager,
                controlService: controlService
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(
                viewModel: viewModel,
                reminderManager: reminderManager,
                controlService: controlService,
                autoPauseManager: autoPauseManager
            )
        } label: {
            Image(nsImage: viewModel.menuBarLabelImage)
        }

        Window("MonitaskMate", id: "main") {
            ContentView(
                viewModel: viewModel,
                reminderManager: reminderManager,
                launchAtLoginManager: launchAtLoginManager,
                floatingCounterManager: floatingCounterManager,
                controlService: controlService,
                autoPauseManager: autoPauseManager
            )
                .frame(minWidth: 360, minHeight: 240)
        }
    }
}
