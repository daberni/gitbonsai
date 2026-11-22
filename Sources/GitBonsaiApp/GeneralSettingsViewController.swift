import AppKit
import GitEngine

/// General: the editors and the terminal behind "Open in editor" and "Open in terminal", and the folders the empty tab suggests repositories from.
final class GeneralSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let editors = AppListControl(kind: .editor)
        form.addRow(LocalizedStringResource("settings.general.editors.label", defaultValue: "Editors", bundle: .module), editors)
        form.addCaption(SettingsForm.caption(LocalizedStringResource("settings.general.editors.caption", defaultValue: "The command bar (⇧⌘P) offers the checked editors under “Open in editor with…”.", bundle: .module)))
        form.addRow(LocalizedStringResource("settings.general.defaultEditor.label", defaultValue: "Default editor", bundle: .module), editors.defaultPicker)
        form.addCaption(SettingsForm.caption(LocalizedStringResource("settings.general.defaultEditor.caption", defaultValue: "Opens worktrees with “Open in editor” and files from their context menu.", bundle: .module)))
        let terminals = AppListControl(kind: .terminal)
        form.addRow(LocalizedStringResource("settings.general.terminals.label", defaultValue: "Terminals", bundle: .module), terminals)
        form.addCaption(SettingsForm.caption(LocalizedStringResource("settings.general.terminals.caption", defaultValue: "The command bar offers the checked terminals under “Open in terminal with…”.", bundle: .module)))
        form.addRow(LocalizedStringResource("settings.general.defaultTerminal.label", defaultValue: "Default terminal", bundle: .module), terminals.defaultPicker)
        form.addCaption(SettingsForm.caption(LocalizedStringResource("settings.general.defaultTerminal.caption", defaultValue: "Opens repositories and worktrees with “Open in terminal”.", bundle: .module)))
        let folders = FolderListControl(read: { AppSettings.repositoryFolders }, write: { AppSettings.repositoryFolders = $0 })
        form.addRow(LocalizedStringResource("settings.general.repositoryFolders.label", defaultValue: "Repository folders", bundle: .module), folders)
        form.addCaption(SettingsForm.caption(LocalizedStringResource("settings.general.repositoryFolders.caption", defaultValue: "A new tab suggests the repositories in these folders, up to \(RepositoryDiscovery.defaultDepth) levels deep.", bundle: .module)))
    }
}
