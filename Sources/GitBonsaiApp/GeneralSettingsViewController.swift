import AppKit
import GitEngine

/// Allgemein: the apps behind "In Editor öffnen" and "Im Terminal öffnen", and the folders the empty tab suggests repositories from.
final class GeneralSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let editor = AppPickerButton(defaultTitle: "Systemstandard", defaultApp: nil, read: { AppSettings.externalEditor }, write: { AppSettings.externalEditor = $0 })
        form.addRow("Editor", editor)
        form.addCaption(SettingsForm.caption("Öffnet Dateien. Der Systemstandard ist die App, die der Finder für die Datei nimmt."))
        let terminalDefault = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ExternalApps.terminalBundleID)
        let terminal = AppPickerButton(defaultTitle: "Terminal", defaultApp: terminalDefault, read: { AppSettings.terminalApp }, write: { AppSettings.terminalApp = $0 })
        form.addRow("Terminal", terminal)
        form.addCaption(SettingsForm.caption("Öffnet Repositories und Worktrees."))
        let folders = FolderListControl(read: { AppSettings.repositoryFolders }, write: { AppSettings.repositoryFolders = $0 })
        form.addRow("Repository-Ordner", folders)
        form.addCaption(SettingsForm.caption("Ein neuer Tab schlägt die Repositories vor, die in diesen Ordnern liegen, bis zu \(RepositoryDiscovery.defaultDepth) Ebenen tief."))
    }
}
