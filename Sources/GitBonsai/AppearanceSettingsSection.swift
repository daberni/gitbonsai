import SwiftUI

/// Part of General: light, dark or the system's choice, applied to every window at once.
struct AppearanceSettingsSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Picker(selection: $model.appearance) {
                ForEach(AppSettings.Appearance.allCases, id: \.self) { appearance in
                    Text(Self.title(appearance)).tag(appearance)
                }
            } label: {
                Text(LocalizedStringResource("settings.appearance.colorScheme.label", defaultValue: "Color scheme", bundle: .module, comment: "Settings label of the light, dark or system choice."))
            }
            .pickerStyle(.segmented)
        }
    }

    private static func title(_ appearance: AppSettings.Appearance) -> LocalizedStringResource {
        switch appearance {
        case .system: LocalizedStringResource("settings.appearance.colorScheme.system", defaultValue: "System", bundle: .module, comment: "Appearance that follows the system.")
        case .light: LocalizedStringResource("settings.appearance.colorScheme.light", defaultValue: "Light", bundle: .module, comment: "Light appearance.")
        case .dark: LocalizedStringResource("settings.appearance.colorScheme.dark", defaultValue: "Dark", bundle: .module, comment: "Dark appearance.")
        }
    }
}
