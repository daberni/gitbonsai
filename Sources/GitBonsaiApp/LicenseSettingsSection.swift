import SwiftUI

/// Part of General: the licensing summary, the purchase link and the optional name shown in About as the licensee.
struct LicenseSettingsSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent {
                Link(destination: License.purchaseURL) { Text(verbatim: License.buyTitle) }
                    .accessibilityIdentifier("settings.general.license.buy")
            } label: {
                Text(verbatim: License.notice)
            }
            TextField(text: $model.licensee, prompt: Text(LocalizedStringResource("settings.general.licensee.placeholder", defaultValue: "Optional", bundle: .module, comment: "Placeholder of the licensee name field."))) {
                Text(LocalizedStringResource("settings.general.licensee.label", defaultValue: "Licensed to", bundle: .module, comment: "Settings label of the name shown as the commercial licensee."))
            }
            .accessibilityIdentifier("settings.general.licensee")
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.general.licensee.caption", defaultValue: "Shown in the About window. GitBonsai does not check it.", bundle: .module))
        }
    }
}
