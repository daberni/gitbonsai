import AppKit

/// The licensing model: free for personal and noncommercial use, a paid license for commercial use, on trust. Nothing here checks or limits anything.
@MainActor
enum License {
    // TODO: point at the checkout once a payment provider exists; until then COMMERCIAL.md explains how to buy.
    static let purchaseURL = URL(string: "https://github.com/daberni/gitbonsai/blob/main/COMMERCIAL.md")!

    static var notice: String {
        String(localized: "common.license.notice", defaultValue: "Personal use is free. Commercial use needs a license.", bundle: .module, comment: "Licensing summary in the About window and the settings.")
    }

    static var buyTitle: String {
        String(localized: "common.license.buy", defaultValue: "Buy a Commercial License", bundle: .module, comment: "Link to buying a license for commercial use.")
    }

    static func licensedTo(_ name: String) -> String {
        String(localized: "window.about.licensedTo", defaultValue: "Licensed to \(name)", bundle: .module, comment: "About window line naming who holds the commercial license; the name as the user entered it.")
    }
}
