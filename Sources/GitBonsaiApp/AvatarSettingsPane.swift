import Avatars
import SwiftUI

/// Avatars: whether author pictures are loaded, and which services learn about the authors for that. Turning them off deletes the caches (`AvatarStore`).
struct AvatarSettingsPane: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.avatarsEnabled) {
                Text(LocalizedStringResource("settings.avatars.load", defaultValue: "Load avatars", bundle: .module, comment: "Toggle for loading author pictures."))
            }
            .accessibilityIdentifier("settings.avatars.load")
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.avatars.authors.caption", defaultValue: "Shows profile pictures instead of initials. The remote's host is asked: GitHub gets the commit SHA, GitLab the email address. Turned off, nothing goes over the network.", bundle: .module))
        }
        Section {
            Picker(selection: $model.avatarSources) {
                ForEach(AvatarSources.allCases, id: \.self) { sources in
                    Text(Self.title(sources)).tag(sources)
                }
            } label: {
                Text(LocalizedStringResource("settings.avatars.sources.label", defaultValue: "Sources", bundle: .module, comment: "Label of the avatar sources choice."))
            }
            .pickerStyle(.radioGroup)
            .disabled(!model.avatarsEnabled)
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.avatars.sources.caption", defaultValue: "Gravatar (gravatar.com) gets the SHA-256 hash of the email address, also for repositories on Bitbucket or your own servers. Pictures stay cached for 7 days, missing ones for 3 days.", bundle: .module))
        }
    }

    private static func title(_ sources: AvatarSources) -> LocalizedStringResource {
        switch sources {
        case .remoteHost: LocalizedStringResource("settings.avatars.sources.remoteHost", defaultValue: "Remote host only", bundle: .module)
        case .remoteHostAndGravatar: LocalizedStringResource("settings.avatars.sources.gravatar", defaultValue: "Gravatar too", bundle: .module)
        }
    }
}
