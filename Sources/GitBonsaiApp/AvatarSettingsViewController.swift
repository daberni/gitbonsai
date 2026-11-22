import AppKit
import Avatars

/// Avatare: whether author pictures are loaded, and which services learn about the authors for that.
final class AvatarSettingsViewController: SettingsPaneController {
    private let enabled = NSButton(checkboxWithTitle: "Avatare laden", target: nil, action: nil)
    private var sourceButtons: [AvatarSources: NSButton] = [:]

    override func buildForm(_ form: SettingsForm) {
        enabled.target = self
        enabled.action = #selector(toggle(_:))
        enabled.state = AppSettings.avatarsEnabled ? .on : .off
        form.addRow("Autoren", enabled)
        form.addCaption(SettingsForm.caption("Zeigt Profilbilder statt Initialen. Gefragt wird der Host des Remotes: GitHub erhält die Commit-SHA, GitLab die E-Mail-Adresse. Ohne Haken geht nichts ins Netz."))
        for (index, sources) in AvatarSources.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: Self.title(of: sources), target: self, action: #selector(choose(_:)))
            sourceButtons[sources] = button
            form.addRow(index == 0 ? "Quellen" : "", button)
        }
        form.addCaption(SettingsForm.caption("Gravatar (gravatar.com) erhält den SHA-256-Hash der E-Mail-Adresse, auch für Repositories auf Bitbucket oder eigenen Servern. Bilder bleiben 7 Tage im Cache, fehlende 3 Tage."))
        update()
    }

    private static func title(of sources: AvatarSources) -> String {
        switch sources {
        case .remoteHost: "Nur vom Remote-Host"
        case .remoteHostAndGravatar: "Auch Gravatar"
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
