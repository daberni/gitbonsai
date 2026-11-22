import Foundation

/// Remembers which repositories were open as tabs and which were used recently, across launches.
@MainActor
final class SessionStore {
    static let recentLimit = 12
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Screenshot runs keep their own state so they never disturb the tabs of a real session.
    static func standard() -> SessionStore {
        let harnessDefaults = ScreenshotHarness.outputPath != nil ? UserDefaults(suiteName: "app.gitbonsai.harness") : nil
        return SessionStore(defaults: harnessDefaults ?? .standard)
    }

    /// Most recently used first; folders that no longer exist are left out.
    var recentRepositories: [String] {
        (defaults.stringArray(forKey: "recentRepositories") ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    func noteOpened(_ path: String) {
        var recents = (defaults.stringArray(forKey: "recentRepositories") ?? []).filter { $0 != path }
        recents.insert(path, at: 0)
        defaults.set(Array(recents.prefix(Self.recentLimit)), forKey: "recentRepositories")
    }

    var openTabs: [String] { defaults.stringArray(forKey: "openTabs") ?? [] }
    var activeTab: Int { defaults.integer(forKey: "activeTab") }

    func saveTabs(_ paths: [String], active: Int) {
        defaults.set(paths, forKey: "openTabs")
        defaults.set(active, forKey: "activeTab")
    }

    var windowPlacement: WindowPlacement? {
        get { defaults.data(forKey: "windowPlacement").flatMap { try? JSONDecoder().decode(WindowPlacement.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "windowPlacement") }
    }

    /// Widths of the sidebar and the detail panel; nil until the user dragged a divider.
    var panelWidths: (sidebar: CGFloat, detail: CGFloat)? {
        guard let sidebar = defaults.object(forKey: "sidebarWidth") as? Double, let detail = defaults.object(forKey: "detailWidth") as? Double else { return nil }
        return (sidebar, detail)
    }

    func savePanelWidths(sidebar: CGFloat, detail: CGFloat) {
        defaults.set(Double(sidebar), forKey: "sidebarWidth")
        defaults.set(Double(detail), forKey: "detailWidth")
    }

    /// Forgets the window's frame and panel widths, so the next window opens with the defaults.
    func forgetLayout() {
        for key in ["windowPlacement", "sidebarWidth", "detailWidth"] { defaults.removeObject(forKey: key) }
    }
}
