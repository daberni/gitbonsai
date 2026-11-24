import AppKit

/// The standard About panel with the licensing summary, the purchase link and the licensee as credits.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: Theme.caption, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString()
        if let licensee = AppSettings.licensee {
            text.append(NSAttributedString(string: License.licensedTo(licensee) + "\n", attributes: base.merging([.font: Theme.bodyMedium, .foregroundColor: NSColor.labelColor]) { $1 }))
        }
        text.append(NSAttributedString(string: License.notice + "\n", attributes: base))
        text.append(NSAttributedString(string: License.buyTitle, attributes: base.merging([.link: License.purchaseURL]) { $1 }))
        return text
    }
}
