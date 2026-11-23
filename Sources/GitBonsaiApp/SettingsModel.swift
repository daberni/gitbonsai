import AppKit
import Avatars
import Observation

/// `AppSettings` for the SwiftUI settings panes. Every property reads and writes the stored preference itself; `revision` follows `AppSettings.didChange`,
/// so a change from anywhere, the harness or another pane included, redraws the views that read it.
@Observable
@MainActor
final class SettingsModel {
    private var revision = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    private func read<Value>(_ value: () -> Value) -> Value {
        _ = revision
        return value()
    }

    var gitPath: String {
        get { read { AppSettings.gitPath ?? "" } }
        set { AppSettings.gitPath = newValue }
    }

    var conflictResolver: AppSettings.ConflictResolver {
        get { read { AppSettings.conflictResolver } }
        set { AppSettings.conflictResolver = newValue }
    }

    var appearance: AppSettings.Appearance {
        get { read { AppSettings.appearance } }
        set { AppSettings.appearance = newValue }
    }

    var language: AppLanguage.Choice {
        get { read { AppSettings.language } }
        set { AppSettings.language = newValue }
    }

    var fetchOnActivation: Bool {
        get { read { AppSettings.fetchOnActivation } }
        set { AppSettings.fetchOnActivation = newValue }
    }

    var autoFetchMinutes: Int {
        get { read { AppSettings.autoFetchMinutes } }
        set { AppSettings.autoFetchMinutes = newValue }
    }

    var avatarsEnabled: Bool {
        get { read { AppSettings.avatarsEnabled } }
        set { AppSettings.avatarsEnabled = newValue }
    }

    var avatarSources: AvatarSources {
        get { read { AppSettings.avatarSources } }
        set { AppSettings.avatarSources = newValue }
    }

    var repositoryFolders: [String] {
        get { read { AppSettings.repositoryFolders } }
        set { AppSettings.repositoryFolders = newValue }
    }

    // MARK: Editors and terminals

    /// The apps found on the system and the added ones, checked or not.
    func apps(_ kind: ExternalApps.Kind) -> [ExternalApps.Choice] {
        read { ExternalApps.choices(kind) }
    }

    /// The app "Open in editor" or "Open in terminal" uses: the chosen default, or the first checked app.
    func defaultApp(_ kind: ExternalApps.Kind) -> String? {
        read { ExternalApps.preferred(kind)?.app.bundleID }
    }

    func makeDefault(_ id: String, _ kind: ExternalApps.Kind) {
        AppSettings.setDefaultApp(id, kind)
    }

    /// An unchecked app leaves the command bar and stops being the default.
    func setShown(_ shown: Bool, _ id: String, _ kind: ExternalApps.Kind) {
        var hidden = AppSettings.hiddenApps(kind).filter { $0 != id }
        if !shown { hidden.append(id) }
        AppSettings.setHiddenApps(hidden, kind)
        if !shown, AppSettings.defaultApp(kind) == id { AppSettings.setDefaultApp(nil, kind) }
    }

    /// Adds an app to the list and checks it again if it was unchecked before.
    func addApp(at url: URL, _ kind: ExternalApps.Kind) {
        guard let app = ExternalApps.app(at: url) else { return }
        if !ExternalApps.choices(kind).contains(where: { $0.app.bundleID == app.bundleID }) { AppSettings.setAddedApps(AppSettings.addedApps(kind) + [url], kind) }
        AppSettings.setHiddenApps(AppSettings.hiddenApps(kind).filter { $0 != app.bundleID }, kind)
    }
}
