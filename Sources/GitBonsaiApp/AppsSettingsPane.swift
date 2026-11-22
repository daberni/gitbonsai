import SwiftUI

/// Apps: the editors and terminals behind "Open in editor" and "Open in terminal", and which of them the command bar offers.
struct AppsSettingsPane: View {
    var body: some View {
        SettingsAppList(kind: .editor)
        SettingsAppList(kind: .terminal)
    }
}
