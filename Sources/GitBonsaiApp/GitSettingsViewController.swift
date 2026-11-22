import AppKit
import GitEngine

/// Git: which git binary the app runs, with its version and a warning when it is too old.
final class GitSettingsViewController: SettingsPaneController {
    private let pathField = NSTextField()
    /// One line, so the section keeps its height while the message changes; long paths are shortened in the middle.
    private let status = SettingsForm.statusLine()
    private var versionCheck: Task<Void, Never>?

    override func buildForm(_ form: SettingsForm) {
        pathField.placeholderString = GitRunner.automaticGitPath()
        pathField.stringValue = AppSettings.gitPath ?? ""
        pathField.usesSingleLineMode = true
        pathField.cell?.wraps = false
        pathField.cell?.isScrollable = true
        pathField.target = self
        pathField.action = #selector(commitPath(_:))
        pathField.widthAnchor.constraint(equalToConstant: Theme.Settings.pathFieldWidth).isActive = true
        let choose = NSButton(title: String(localized: "settings.git.choose", defaultValue: "Select…", bundle: .module), target: self, action: #selector(choosePath(_:)))
        let row = NSStackView(views: [pathField, choose])
        row.spacing = Theme.Settings.columnSpacing
        form.addRow(LocalizedStringResource("settings.git.program.label", defaultValue: "Git program", bundle: .module), row)
        form.addCaption(status)
        form.addCaption(SettingsForm.caption(LocalizedStringResource("settings.git.program.caption", defaultValue: "Leave empty to find git automatically. Applies to repositories opened afterwards.", bundle: .module)))
        showVersion()
    }

    @objc private func commitPath(_ sender: Any?) {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard path.isEmpty || FileManager.default.isExecutableFile(atPath: path) else {
            show(String(localized: "settings.git.noExecutable", defaultValue: "There is no executable at “\(path)”. Not applied.", bundle: .module), color: Theme.persimmon)
            return
        }
        guard path != (AppSettings.gitPath ?? "") else { return showVersion() }
        AppSettings.gitPath = path
        showVersion()
    }

    @objc private func choosePath(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: (GitRunner.defaultGitPath() as NSString).deletingLastPathComponent)
        panel.prompt = String(localized: "settings.git.panelPrompt", defaultValue: "Select", bundle: .module, comment: "The open panel's confirm button for the git program.")
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            pathField.stringValue = url.path
            commitPath(nil)
        }
    }

    /// Asks the git the app would run now for its version.
    private func showVersion() {
        let path = GitRunner.defaultGitPath()
        show(String(localized: "settings.git.checking", defaultValue: "Checking git…", bundle: .module), color: Theme.inkMuted)
        versionCheck?.cancel()
        versionCheck = Task { [weak self] in
            let result: Result<GitVersion, Error>
            do { result = .success(try await GitRunner.version(ofGitAt: path)) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let version) where version < .minimumSupported:
                let found = version.description
                let minimum = "\(GitVersion.minimumSupported.major).\(GitVersion.minimumSupported.minor)"
                show(String(localized: "settings.git.tooOld", defaultValue: "git \(found) is too old. GitBonsai needs git \(minimum) or later.", bundle: .module), color: Theme.ochre)
            case .success(let version):
                let found = version.description
                show(String(localized: "settings.git.found", defaultValue: "git \(found) at \(path)", bundle: .module, comment: "The git version and the path of the git program."), color: Theme.inkMuted)
            case .failure:
                show(String(localized: "settings.git.notGit", defaultValue: "This program doesn't identify itself as git.", bundle: .module), color: Theme.persimmon)
            }
        }
    }

    private func show(_ text: String, color: NSColor) {
        status.stringValue = text
        status.textColor = color
    }
}
