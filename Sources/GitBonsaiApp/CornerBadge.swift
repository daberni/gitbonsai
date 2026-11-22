import AppKit

/// A small opaque capsule pinned to a corner of a control, such as the commit counts on the toolbar's Pull and Push buttons.
/// It floats above its anchor without taking part in layout, so the control keeps its size and place whether the badge shows or not.
final class CornerBadge: NSView {
    enum Tone {
        /// Informs, for example about commits to pull or push.
        case info
        /// Signals danger, for example a branch without upstream.
        case danger
    }

    enum Content: Equatable {
        case count(Int)
        case symbol(String)
    }

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var tone = Tone.info

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        label.font = Theme.Badge.font
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Badge.symbolSize, weight: .bold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        for view in [label, icon] { addSubview(view) }
        // The capsule is as narrow as its content allows.
        let hug = widthAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.Badge.height),
            widthAnchor.constraint(greaterThanOrEqualTo: heightAnchor),
            hug,
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.Badge.padding),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The badge's text as shown, "" for a symbol; for harness output.
    var text: String { isHidden ? "" : label.stringValue }

    /// Shows the content in the tone, or hides the badge for nil and for a count of 0: a badge without meaning is noise.
    func show(_ content: Content?, tone: Tone = .info) {
        self.tone = tone
        switch content {
        case .count(let count) where count > 0:
            label.stringValue = count > Theme.Badge.maximumCount ? "\(Theme.Badge.maximumCount)+" : "\(count)"
            label.isHidden = false
            icon.isHidden = true
        case .symbol(let name):
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            icon.isHidden = false
            label.isHidden = true
            label.stringValue = ""
        default:
            isHidden = true
            return
        }
        isHidden = false
        needsDisplay = true
    }

    /// Clicks and tooltips belong to the control underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill = tone == .danger ? Theme.persimmon : Theme.sky
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
        }
        layer?.cornerRadius = Theme.Badge.height / 2
        label.textColor = Theme.Badge.onAccent
        icon.contentTintColor = Theme.Badge.onAccent
    }
}
