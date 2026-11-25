import GitEngine
import SwiftUI

/// The folders the empty tab suggests repositories from, as one section: a row per folder with its remove button, "Add folder…" below.
struct SettingsFolderList: View {
    @Environment(SettingsModel.self) private var model
    @State private var adding = false

    var body: some View {
        let folders = model.repositoryFolders
        Section {
            ForEach(folders, id: \.self) { folder in
                HStack(spacing: Theme.Space.s) {
                    Label {
                        Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .help(folder)
                    Spacer(minLength: Theme.Space.s)
                    Button {
                        model.repositoryFolders = folders.filter { $0 != folder }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.inkMuted)
                    .pointerStyle(.link)
                    .accessibilityLabel(Text(LocalizedStringResource("settings.folders.remove", defaultValue: "Remove folder", bundle: .module)))
                    .accessibilityIdentifier("settings.folders.remove.\(folder)")
                }
            }
            Button {
                adding = true
            } label: {
                Text(LocalizedStringResource("settings.folders.add", defaultValue: "Add folder…", bundle: .module, comment: "Adds folders to search for repositories."))
            }
        } header: {
            Text(LocalizedStringResource("settings.general.repositoryFolders.label", defaultValue: "Repository folders", bundle: .module, comment: "Settings section of the folders searched for repositories."))
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.general.repositoryFolders.caption", defaultValue: "A new tab suggests the repositories in these folders, up to \(RepositoryDiscovery.defaultDepth) levels deep.", bundle: .module))
        }
        .fileImporter(isPresented: $adding, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            model.repositoryFolders = folders + urls.map(\.path).filter { !folders.contains($0) }
        }
        .fileDialogMessage(Text(LocalizedStringResource("settings.folders.panelMessage", defaultValue: "Choose folders to search for repositories.", bundle: .module)))
        .fileDialogConfirmationLabel(Text(LocalizedStringResource("common.add", defaultValue: "Add", bundle: .module, comment: "The open panel's confirm button for adding an app or folder.")))
    }
}
