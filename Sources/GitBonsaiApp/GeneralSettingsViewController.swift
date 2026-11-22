import AppKit
import GitEngine

/// General: the editors and the terminal behind "Open in editor" and "Open in terminal", and the folders the empty tab suggests repositories from.
final class GeneralSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let editors = AppListControl(kind: .editor)
        form.addRow("Editors", editors)
        form.addCaption(SettingsForm.caption("The command bar (⇧⌘P) offers the checked editors under “Open in editor with…”."))
        form.addRow("Default editor", editors.defaultPicker)
        form.addCaption(SettingsForm.caption("Opens worktrees with “Open in editor” and files from their context menu."))
        let terminals = AppListControl(kind: .terminal)
        form.addRow("Terminals", terminals)
        form.addCaption(SettingsForm.caption("The command bar offers the checked terminals under “Open in terminal with…”."))
        form.addRow("Default terminal", terminals.defaultPicker)
        form.addCaption(SettingsForm.caption("Opens repositories and worktrees with “Open in terminal”."))
        let folders = FolderListControl(read: { AppSettings.repositoryFolders }, write: { AppSettings.repositoryFolders = $0 })
        form.addRow("Repository folders", folders)
        form.addCaption(SettingsForm.caption("A new tab suggests the repositories in these folders, up to \(RepositoryDiscovery.defaultDepth) levels deep."))
    }
}
