import GitEngine
import SwiftUI

/// Part of Git: whether the visible repository fetches on activation, and how often it fetches while it stays visible.
struct FetchSettingsSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.fetchOnActivation) {
                Text(LocalizedStringResource("settings.fetch.onActivation", defaultValue: "Fetch on activation", bundle: .module, comment: "Toggle for fetching when the app or a tab becomes active."))
            }
            .accessibilityIdentifier("settings.fetch.onActivation")
        } header: {
            Text(LocalizedStringResource("settings.fetch.automatic.label", defaultValue: "Automatic fetch", bundle: .module, comment: "Settings section of the automatic fetch."))
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.fetch.automatic.caption", defaultValue: "Every time the app becomes active or a tab becomes visible, independent of the periodic fetch. Switching back within a few seconds does not fetch again.", bundle: .module))
        }
        Section {
            Picker(selection: $model.autoFetchMinutes) {
                ForEach(AutoFetchPolicy.intervalChoices, id: \.self) { minutes in
                    Text(Self.title(minutes)).tag(minutes)
                }
            } label: {
                Text(LocalizedStringResource("settings.fetch.periodic.label", defaultValue: "Periodically", bundle: .module, comment: "Label of the periodic fetch interval."))
            }
        } footer: {
            SettingsCaption(LocalizedStringResource("settings.fetch.periodic.caption", defaultValue: "Only the visible repository, while the app is active, with git fetch --all --prune. Half as often on battery, not at all in Low Power Mode.", bundle: .module))
        }
    }

    private static func title(_ minutes: Int) -> LocalizedStringResource {
        if minutes == 0 { return LocalizedStringResource("settings.fetch.periodicOff", defaultValue: "Off", bundle: .module, comment: "Periodic fetch is off.") }
        return LocalizedStringResource("settings.fetch.everyMinutes", defaultValue: "Every \(minutes) minutes", bundle: .module, comment: "Periodic fetch interval.")
    }
}
