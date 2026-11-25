import GitEngine
import SwiftUI

/// Git: what "Resolve…" of a conflicted file opens. GitBonsai's merge window, or a tool git can open in a window, stored as `merge.guitool` in the global git config.
/// Terminal tools such as vimdiff are not offered, as the app has no terminal for them.
struct MergeToolSettingsSection: View {
    private enum Choice: Hashable {
        case gitBonsai
        case tool(String)
    }

    @Environment(SettingsModel.self) private var model
    @State private var tools: [MergeTool] = []
    @State private var globalTool: String?
    @State private var failure: String?

    var body: some View {
        Section {
            Picker(selection: selection) {
                Text(LocalizedStringResource("settings.git.mergeTool.gitBonsai", defaultValue: "GitBonsai merge window", bundle: .module, comment: "Choice of the merge tool setting: the app's own merge window."))
                    .tag(Choice.gitBonsai)
                if !offered.isEmpty {
                    Divider()
                    ForEach(offered) { tool in
                        Text(verbatim: tool.isUserDefined ? tool.name : "\(tool.name) – \(tool.summary)").tag(Choice.tool(tool.name))
                    }
                }
            } label: {
                Text(LocalizedStringResource("settings.git.mergeTool.label", defaultValue: "Resolve conflicts with", bundle: .module, comment: "Label of the merge tool setting."))
            }
            .accessibilityIdentifier("settings.git.mergeTool")
            if let failure {
                Text(verbatim: failure).font(.themeCaption).foregroundStyle(.persimmon).lineLimit(2)
            }
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.git.mergeTool.caption", defaultValue: "Another tool is stored as merge.guitool in your global git config, so git mergetool --gui opens it as well. A repository that sets its own merge.guitool uses that one.", bundle: .module))
        }
        .task(id: model.gitPath) { await load() }
    }

    /// Tools that open a window and that git found, and the configured one even if git no longer finds it.
    private var offered: [MergeTool] {
        var shown = tools.filter { $0.isGraphical && $0.isAvailable }
        if let globalTool, !shown.contains(where: { $0.name == globalTool }) {
            shown.insert(tools.first { $0.name == globalTool } ?? MergeTool(name: globalTool, summary: "", isGraphical: true, isAvailable: false, isUserDefined: true), at: 0)
        }
        return shown
    }

    private var selection: Binding<Choice> {
        Binding {
            if model.conflictResolver == .mergeTool, let globalTool { return .tool(globalTool) }
            return .gitBonsai
        } set: { choice in
            switch choice {
            case .gitBonsai:
                // The git config stays as it is; git mergetool on the command line keeps the user's tool.
                model.conflictResolver = .gitBonsai
            case .tool(let name):
                Task { await choose(name) }
            }
        }
    }

    private func choose(_ name: String) async {
        do {
            try await MergeTools.setGlobalGuiTool(name)
            globalTool = name
            failure = nil
            model.conflictResolver = .mergeTool
        } catch {
            failure = (error as? GitError)?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? error.localizedDescription
        }
    }

    private func load() async {
        let found = (try? await MergeTools.all()) ?? []
        let configured = try? await MergeTools.globalGuiTool()
        guard !Task.isCancelled else { return }
        tools = found
        globalTool = configured ?? nil
    }
}
