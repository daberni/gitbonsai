import GitEngine
import SwiftUI

/// General: the color scheme, the folders the empty tab suggests repositories from, the order of the history, and the interface language, applied on the next launch.
struct GeneralSettingsPane: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        AppearanceSettingsSection()
        SettingsFolderList()
        Section {
            Picker(selection: $model.historyOrder) {
                ForEach(HistoryOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                Text(LocalizedStringResource("settings.general.historyOrder.label", defaultValue: "History order", bundle: .module, comment: "Settings label of how the history sorts commits across branches."))
            }
            .accessibilityIdentifier("settings.general.historyOrder")
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.general.historyOrder.caption", defaultValue: "Every order lists a commit above its parents.", bundle: .module))
        }
        Section {
            Picker(selection: $model.language) {
                ForEach(AppLanguage.Choice.allCases, id: \.self) { language in
                    Text(Self.title(language)).tag(language)
                }
            } label: {
                Text(LocalizedStringResource("settings.general.language.label", defaultValue: "Language", bundle: .module, comment: "Settings label of the interface language choice."))
            }
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.general.language.caption", defaultValue: "Takes effect the next time GitBonsai starts.", bundle: .module))
        }
    }

    /// Each language is named in itself, so it can be found whatever the interface shows now.
    private static func title(_ language: AppLanguage.Choice) -> LocalizedStringResource {
        switch language {
        case .system: LocalizedStringResource("settings.general.language.system", defaultValue: "System Language", bundle: .module, comment: "Interface language that follows the system's language order.")
        case .de: .verbatim("Deutsch")
        case .en: .verbatim("English")
        }
    }
}
