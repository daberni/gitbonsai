import AppKit

/// A short note at the bottom of the history pane that fades out by itself, for things worth knowing that need no answer, such as commits a rebase left out.
@MainActor
final class Toast {
    let view = ToastView()
    /// Each message starts a new countdown; only the latest one may hide the toast.
    private var generation = 0

    init() {
        view.isHidden = true
        view.alphaValue = 0
    }

    /// Puts the toast on top of `host`, centred above its bottom edge.
    func install(in container: NSView, above host: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Theme.Toast.margin),
            view.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -2 * Theme.Toast.margin),
        ])
    }

    func show(_ text: String) {
        generation += 1
        let current = generation
        view.text = text
        view.isHidden = false
        if ScreenshotHarness.isActive { FileHandle.standardError.write(Data("toast: \(text)\n".utf8)) }
        fade(to: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Toast.duration) { [weak self] in
            guard let self, current == generation else { return }
            fade(to: 0) { [weak self] in
                guard let self, current == generation else { return }
                view.isHidden = true
            }
        }
    }

    private func fade(to alpha: CGFloat, then completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Toast.fade
            view.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }
}

/// A rounded, outlined pill with a glyph and one line of text; it lets clicks through to the history below.
final class ToastView: NSView {
    private typealias M = Theme.Toast
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    init() {
        super.init(frame: .zero)
        glyph.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Icon.small, weight: .medium)
        glyph.contentTintColor = Theme.moss
        label.font = Theme.bodyMedium
        label.textColor = Theme.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [glyph, label])
        row.spacing = Theme.Space.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: M.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.padding),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.Stroke.hairline / 2, dy: Theme.Stroke.hairline / 2), xRadius: M.radius, yRadius: M.radius)
        Theme.surface2.setFill()
        shape.fill()
        Theme.hairline.setStroke()
        shape.lineWidth = Theme.Stroke.hairline
        shape.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
