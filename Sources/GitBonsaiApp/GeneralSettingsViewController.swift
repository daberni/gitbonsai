import AppKit
import GitEngine

/// Allgemein: the editors and the terminal behind "Im Editor öffnen" and "Im Terminal öffnen", and the folders the empty tab suggests repositories from.
final class GeneralSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let editors = EditorListControl()
        form.addRow("Editoren", editors)
        form.addCaption(SettingsForm.caption("Angehakte Editoren bietet die Befehlsleiste (⇧⌘P) unter „Im Editor öffnen …“ an."))
        form.addRow("Standard-Editor", editors.defaultPicker)
        form.addCaption(SettingsForm.caption("Öffnet Worktrees mit „Im Editor öffnen“ und Dateien aus ihrem Kontextmenü."))
        let terminalDefault = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ExternalApps.terminalBundleID)
        let detectedTerminals = ExternalApps.installedTerminals().map(\.url)
        let terminal = AppPickerButton(defaultTitle: "Terminal", defaultApp: terminalDefault, suggestions: detectedTerminals, read: { AppSettings.terminalApp }, write: { AppSettings.terminalApp = $0 })
        form.addRow("Terminal", terminal)
        form.addCaption(SettingsForm.caption("Öffnet Repositories und Worktrees."))
        let folders = FolderListControl(read: { AppSettings.repositoryFolders }, write: { AppSettings.repositoryFolders = $0 })
        form.addRow("Repository-Ordner", folders)
        form.addCaption(SettingsForm.caption("Ein neuer Tab schlägt die Repositories vor, die in diesen Ordnern liegen, bis zu \(RepositoryDiscovery.defaultDepth) Ebenen tief."))
    }
}
