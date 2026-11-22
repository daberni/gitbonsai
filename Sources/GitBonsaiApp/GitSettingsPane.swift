import GitEngine
import SwiftUI

/// Git: which git binary the app runs, with its version and a warning when it is too old.
struct GitSettingsPane: View {
    private enum Status {
        case checking
        case found(GitVersion, path: String)
        case tooOld(GitVersion)
        case notGit
        case notExecutable(String)
    }

    @Environment(SettingsModel.self) private var model
    @State private var text = ""
    @State private var status = Status.checking
    @State private var choosing = false
    @FocusState private var editing: Bool

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: Theme.Settings.columnSpacing) {
                    TextField(text: $text, prompt: Text(verbatim: GitRunner.automaticGitPath())) { Text(Self.programLabel) }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .focused($editing)
                        .onSubmit(commit)
                        .frame(width: Theme.Settings.pathFieldWidth)
                    Button {
                        choosing = true
                    } label: {
                        Text(LocalizedStringResource("settings.git.choose", defaultValue: "Select…", bundle: .module, comment: "Opens a panel to choose the git program."))
                    }
                }
            } label: {
                Text(Self.programLabel)
            }
            // One line, so the section keeps its height while the message changes; long paths are shortened in the middle.
            statusLine
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("settings.git.status")
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.git.program.caption", defaultValue: "Leave empty to find git automatically. Applies to repositories opened afterwards.", bundle: .module))
        }
        .onAppear { text = model.gitPath }
        .onChange(of: editing) { _, isEditing in if !isEditing { commit() } }
        // Asks the git the app would run now for its version, again whenever the setting changes.
        .task(id: model.gitPath) { await checkVersion() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            text = url.path
            commit()
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: (GitRunner.defaultGitPath() as NSString).deletingLastPathComponent))
        .fileDialogConfirmationLabel(Text(LocalizedStringResource("settings.git.panelPrompt", defaultValue: "Select", bundle: .module, comment: "The open panel's confirm button for the git program.")))
    }

    private static let programLabel = LocalizedStringResource("settings.git.program.label", defaultValue: "Git program", bundle: .module, comment: "Label of the git binary path.")

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .checking:
            Text(LocalizedStringResource("settings.git.checking", defaultValue: "Checking git…", bundle: .module)).font(.themeCaption).foregroundStyle(.inkMuted)
        case .found(let version, let path):
            let found = version.description
            Text(LocalizedStringResource("settings.git.found", defaultValue: "git \(found) at \(path)", bundle: .module, comment: "The git version and the path of the git program.")).font(.themeCaption).foregroundStyle(.inkMuted)
        case .tooOld(let version):
            let found = version.description
            let minimum = "\(GitVersion.minimumSupported.major).\(GitVersion.minimumSupported.minor)"
            Text(LocalizedStringResource("settings.git.tooOld", defaultValue: "git \(found) is too old. GitBonsai needs git \(minimum) or later.", bundle: .module)).font(.themeCaption).foregroundStyle(.ochre)
        case .notGit:
            Text(LocalizedStringResource("settings.git.notGit", defaultValue: "This program doesn't identify itself as git.", bundle: .module)).font(.themeCaption).foregroundStyle(.persimmon)
        case .notExecutable(let path):
            Text(LocalizedStringResource("settings.git.noExecutable", defaultValue: "There is no executable at “\(path)”. Not applied.", bundle: .module)).font(.themeCaption).foregroundStyle(.persimmon)
        }
    }

    private func commit() {
        let path = text.trimmingCharacters(in: .whitespaces)
        guard path.isEmpty || FileManager.default.isExecutableFile(atPath: path) else {
            status = .notExecutable(path)
            return
        }
        if path == model.gitPath {
            Task { await checkVersion() }
        } else {
            model.gitPath = path
        }
    }

    private func checkVersion() async {
        let path = GitRunner.defaultGitPath()
        status = .checking
        let result: Status
        do {
            let version = try await GitRunner.version(ofGitAt: path)
            result = version < .minimumSupported ? .tooOld(version) : .found(version, path: path)
        } catch {
            result = .notGit
        }
        guard !Task.isCancelled else { return }
        status = result
    }
}
