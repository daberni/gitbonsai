import AppKit
import GitEngine

/// Allgemein: the editors and the terminal behind "Im Editor öffnen" and "Im Terminal öffnen", and the folders the empty tab suggests repositories from.
final class GeneralSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let editors = AppListControl(kind: .editor)
        form.addRow("Editoren", editors)
        form.addCaption(SettingsForm.caption("Angehakte Editoren bietet die Befehlsleiste (⇧⌘P) unter „Im Editor öffnen mit …“ an."))
        form.addRow("Standard-Editor", editors.defaultPicker)
        form.addCaption(SettingsForm.caption("Öffnet Worktrees mit „Im Editor öffnen“ und Dateien aus ihrem Kontextmenü."))
        let terminals = AppListControl(kind: .terminal)
        form.addRow("Terminals", terminals)
        form.addCaption(SettingsForm.caption("Angehakte Terminals bietet die Befehlsleiste unter „Im Terminal öffnen mit …“ an."))
        form.addRow("Standard-Terminal", terminals.defaultPicker)
        form.addCaption(SettingsForm.caption("Öffnet Repositories und Worktrees mit „Im Terminal öffnen“."))
        let folders = FolderListControl(read: { AppSettings.repositoryFolders }, write: { AppSettings.repositoryFolders = $0 })
        form.addRow("Repository-Ordner", folders)
        form.addCaption(SettingsForm.caption("Ein neuer Tab schlägt die Repositories vor, die in diesen Ordnern liegen, bis zu \(RepositoryDiscovery.defaultDepth) Ebenen tief."))
    }
}
