import AppKit

/// What the harness reaches of the running app. The composition root hands its context over once; nothing in the app reads it from here.
@MainActor
extension ScreenshotHarness {
    /// The app's context, for switches that change preferences or open app windows.
    static var app: AppContext!
    /// The settings window, created on first use by the app delegate.
    static var settingsWindow: (() -> SettingsWindowController)!

    static func attach(_ context: AppContext, settingsWindow: @escaping () -> SettingsWindowController) {
        app = context
        self.settingsWindow = settingsWindow
    }

    /// Stores the preferences that harness switches ask for in the run's defaults, before any service reads them. Runs show initials unless `GITBONSAI_AVATARS` asks for pictures.
    static func applySettingSwitches(to settings: AppSettings) {
        guard isActive else { return }
        applyAvatarSwitches(settings)
        applyHistoryOrderSwitch(settings)
        applyRepositoryFolders(settings)
        applyLicensee(settings)
    }
}
