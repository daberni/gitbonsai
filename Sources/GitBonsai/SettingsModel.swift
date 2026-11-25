import AppKit
import Avatars
import GitEngine
import Observation

/// The app's `AppSettings` for the SwiftUI settings panes. Every property reads and writes the stored preference itself; `revision` follows `AppSettings.didChange`,
/// so a change from anywhere, another pane included, redraws the views that read it.
@Observable
@MainActor
final class SettingsModel {
    private var revision = 0
    @ObservationIgnored private let observers = NotificationObservers()

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        observers.observe(AppSettings.didChange, object: settings) { [weak self] in self?.revision += 1 }
    }

    private func read<Value>(_ value: () -> Value) -> Value {
        _ = revision
        return value()
    }

    var gitPath: String {
        get { read { settings.gitPath ?? "" } }
        set { settings.gitPath = newValue }
    }

    var conflictResolver: AppSettings.ConflictResolver {
        get { read { settings.conflictResolver } }
        set { settings.conflictResolver = newValue }
    }

    var appearance: AppSettings.Appearance {
        get { read { settings.appearance } }
        set { settings.appearance = newValue }
    }

    var language: AppLanguage.Choice {
        get { read { settings.language } }
        set { settings.language = newValue }
    }

    var historyOrder: HistoryOrder {
        get { read { settings.historyOrder } }
        set { settings.historyOrder = newValue }
    }

    var fetchOnActivation: Bool {
        get { read { settings.fetchOnActivation } }
        set { settings.fetchOnActivation = newValue }
    }

    var autoFetchMinutes: Int {
        get { read { settings.autoFetchMinutes } }
        set { settings.autoFetchMinutes = newValue }
    }

    var avatarMode: AvatarMode {
        get { read { settings.avatarMode } }
        set { settings.avatarMode = newValue }
    }

    var licensee: String {
        get { read { settings.licensee ?? "" } }
        set { settings.licensee = newValue }
    }

    var repositoryFolders: [String] {
        get { read { settings.repositoryFolders } }
        set { settings.repositoryFolders = newValue }
    }

    // MARK: Editors and terminals

    /// The apps found on the system and the added ones, checked or not.
    func apps(_ kind: ExternalApps.Kind) -> [ExternalApps.Choice] {
        read { ExternalApps.choices(kind, settings: settings) }
    }

    /// The app "Open in editor" or "Open in terminal" uses: the chosen default, or the first checked app.
    func defaultApp(_ kind: ExternalApps.Kind) -> String? {
        read { ExternalApps.preferred(kind, settings: settings)?.app.bundleID }
    }

    func makeDefault(_ id: String, _ kind: ExternalApps.Kind) {
        settings.setDefaultApp(id, kind)
    }

    /// An unchecked app leaves the command bar and stops being the default.
    func setShown(_ shown: Bool, _ id: String, _ kind: ExternalApps.Kind) {
        var hidden = settings.hiddenApps(kind).filter { $0 != id }
        if !shown { hidden.append(id) }
        settings.setHiddenApps(hidden, kind)
        if !shown, settings.defaultApp(kind) == id { settings.setDefaultApp(nil, kind) }
    }

    /// Adds an app to the list and checks it again if it was unchecked before.
    func addApp(at url: URL, _ kind: ExternalApps.Kind) {
        guard let app = ExternalApps.app(at: url) else { return }
        if !ExternalApps.choices(kind, settings: settings).contains(where: { $0.app.bundleID == app.bundleID }) { settings.setAddedApps(settings.addedApps(kind) + [url], kind) }
        settings.setHiddenApps(settings.hiddenApps(kind).filter { $0 != app.bundleID }, kind)
    }
}
