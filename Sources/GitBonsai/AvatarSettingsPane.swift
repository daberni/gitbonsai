import Avatars
import SwiftUI

/// Avatars: plain initials, or pictures from the remote host and optionally Gravatar. Choosing initials only deletes the caches (`AvatarStore`).
/// The caption says what leaves the machine for the current choice; every caption takes the same space, so the pane never changes height.
struct AvatarSettingsPane: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Picker(selection: $model.avatarMode) {
                ForEach(AvatarMode.allCases, id: \.self) { mode in
                    Text(Self.title(mode)).tag(mode)
                }
            } label: {
                Text(LocalizedStringResource("settings.avatars.mode.label", defaultValue: "Avatars", bundle: .module, comment: "Label of the choice between initials and profile pictures from the network."))
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings.avatars.mode")
        } footer: {
            ZStack(alignment: .topLeading) {
                ForEach(AvatarMode.allCases, id: \.self) { mode in
                    SettingsCaption(Self.caption(mode))
                        .opacity(mode == model.avatarMode ? 1 : 0)
                        .accessibilityHidden(mode != model.avatarMode)
                }
            }
        }
    }

    private static func title(_ mode: AvatarMode) -> LocalizedStringResource {
        switch mode {
        case .initialsOnly: LocalizedStringResource("settings.avatars.mode.initialsOnly", defaultValue: "Initials only", bundle: .module, comment: "Avatar choice: plain initials, no network.")
        case .remoteHost: LocalizedStringResource("settings.avatars.mode.remoteHost", defaultValue: "From the remote host", bundle: .module, comment: "Avatar choice: pictures from the host of the repository's remote, such as GitHub or GitLab.")
        case .remoteHostAndGravatar: LocalizedStringResource("settings.avatars.mode.remoteHostAndGravatar", defaultValue: "Remote host and Gravatar", bundle: .module, comment: "Avatar choice: pictures from the remote's host, then from Gravatar.")
        }
    }

    private static func caption(_ mode: AvatarMode) -> LocalizedStringResource {
        switch mode {
        case .initialsOnly: LocalizedStringResource("settings.avatars.mode.caption.initialsOnly", defaultValue: "Nothing leaves this Mac.", bundle: .module, comment: "What is sent for avatars with initials only.")
        case .remoteHost: LocalizedStringResource("settings.avatars.mode.caption.remoteHost", defaultValue: "The remote host gets commit SHAs or author email addresses.", bundle: .module, comment: "What is sent for avatars from the remote host.")
        case .remoteHostAndGravatar: LocalizedStringResource("settings.avatars.mode.caption.remoteHostAndGravatar", defaultValue: "The remote host gets commit SHAs or email addresses, Gravatar their hashes.", bundle: .module, comment: "What is sent for avatars from the remote host and Gravatar.")
        }
    }
}
