import AppKit
import SwiftUI

/// The editors or terminals of Settings → General as one section: the apps found on the system and the added ones, each checked when the command bar offers it,
/// the default marked with a pill and chosen right in its row, and "Add other app…" below.
struct SettingsAppList: View {
    let kind: ExternalApps.Kind
    @Environment(SettingsModel.self) private var model
    @State private var adding = false

    var body: some View {
        let defaultID = model.defaultApp(kind)
        Section {
            ForEach(model.apps(kind), id: \.app.bundleID) { choice in
                AppRow(choice: choice, kind: kind, isDefault: choice.app.bundleID == defaultID)
            }
            Button {
                adding = true
            } label: {
                Text(LocalizedStringResource("settings.apps.addOther", defaultValue: "Add other app…", bundle: .module, comment: "Adds an editor or terminal the app did not find."))
            }
        } header: {
            switch kind {
            case .editor: Text(LocalizedStringResource("settings.apps.editors.label", defaultValue: "Editors", bundle: .module, comment: "Settings section of the editors."))
            case .terminal: Text(LocalizedStringResource("settings.apps.terminals.label", defaultValue: "Terminals", bundle: .module, comment: "Settings section of the terminals."))
            }
        } footer: {
            switch kind {
            case .editor: SettingsCaption(LocalizedStringResource("settings.apps.editors.caption", defaultValue: "The command bar (⇧⌘P) offers the checked editors under “Open in editor with…”. The default opens worktrees with “Open in editor” and files from their context menu; point at another editor to make it the default.", bundle: .module))
            case .terminal: SettingsCaption(LocalizedStringResource("settings.apps.terminals.caption", defaultValue: "The command bar offers the checked terminals under “Open in terminal with…”. The default opens repositories and worktrees with “Open in terminal”; point at another terminal to make it the default.", bundle: .module))
            }
        }
        .fileImporter(isPresented: $adding, allowedContentTypes: [.application]) { result in
            guard case .success(let url) = result else { return }
            model.addApp(at: url, kind)
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications"))
        .fileDialogConfirmationLabel(Text(LocalizedStringResource("common.add", defaultValue: "Add", bundle: .module, comment: "The open panel's confirm button for adding an app or folder.")))
    }
}

/// One app: its checkbox with icon and name, then the default's pill or, while the pointer is on the row, the button that makes it the default.
private struct AppRow: View {
    let choice: ExternalApps.Choice
    let kind: ExternalApps.Kind
    let isDefault: Bool
    @Environment(SettingsModel.self) private var model
    @State private var hovering = false

    private static let makeDefault = LocalizedStringResource("settings.apps.makeDefault", defaultValue: "Make default", bundle: .module, comment: "Makes this editor or terminal the default.")

    var body: some View {
        let id = choice.app.bundleID
        HStack(spacing: Theme.Space.s) {
            Toggle(isOn: Binding(get: { choice.isShown }, set: { model.setShown($0, id, kind) })) {
                HStack(spacing: Theme.Space.xs) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: choice.url.path))
                        .resizable()
                        .frame(width: Theme.Settings.appIcon, height: Theme.Settings.appIcon)
                        .accessibilityHidden(true)
                    Text(verbatim: choice.app.name).lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("settings.apps.\(id)")
            .accessibilityActions {
                if choice.isShown && !isDefault { Button(Self.makeDefault) { model.makeDefault(id, kind) } }
            }
            Spacer(minLength: Theme.Space.s)
            if isDefault {
                PillLabel(text: LocalizedStringResource("common.default", defaultValue: "Default", bundle: .module, comment: "Marks the default app in the list of editors or terminals."))
            } else if choice.isShown {
                // Shown on hover only, so the list reads as names and one pill. VoiceOver and the keyboard use the row's action and context menu instead,
                // since SwiftUI drops a transparent view from the accessibility tree.
                Button(Self.makeDefault) { model.makeDefault(id, kind) }
                    .controlSize(.small)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .contextMenu {
            if choice.isShown && !isDefault { Button(Self.makeDefault) { model.makeDefault(id, kind) } }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(choice.url.path)
    }
}
