import AppKit
import Avatars

/// Avatars: whether author pictures are loaded, and which services learn about the authors for that.
final class AvatarSettingsViewController: SettingsPaneController {
    private let enabled = NSButton(checkboxWithTitle: String(localized: "Load avatars", bundle: .module), target: nil, action: nil)
    private var sourceButtons: [AvatarSources: NSButton] = [:]

    override func buildForm(_ form: SettingsForm) {
        enabled.target = self
        enabled.action = #selector(toggle(_:))
        enabled.state = AppSettings.avatarsEnabled ? .on : .off
        form.addRow("Authors", enabled)
        form.addCaption(SettingsForm.caption("Shows profile pictures instead of initials. The remote's host is asked: GitHub gets the commit SHA, GitLab the email address. Unchecked, nothing goes over the network."))
        for (index, sources) in AvatarSources.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: Self.title(of: sources), target: self, action: #selector(choose(_:)))
            sourceButtons[sources] = button
            form.addRow(index == 0 ? "Sources" : nil, button)
        }
        form.addCaption(SettingsForm.caption("Gravatar (gravatar.com) gets the SHA-256 hash of the email address, also for repositories on Bitbucket or your own servers. Pictures stay cached for 7 days, missing ones for 3 days."))
        update()
    }

    private static func title(of sources: AvatarSources) -> String {
        switch sources {
        case .remoteHost: String(localized: "Remote host only", bundle: .module)
        case .remoteHostAndGravatar: String(localized: "Gravatar too", bundle: .module)
        }
    }

    private func update() {
        for (sources, button) in sourceButtons {
            button.state = sources == AppSettings.avatarSources ? .on : .off
            button.isEnabled = AppSettings.avatarsEnabled
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        AppSettings.avatarsEnabled = sender.state == .on
        update()
    }

    @objc private func choose(_ sender: NSButton) {
        guard let sources = sourceButtons.first(where: { $0.value === sender })?.key else { return }
        AppSettings.avatarSources = sources
        update()
    }
}
