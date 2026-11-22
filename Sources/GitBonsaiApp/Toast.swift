import AppKit

/// The one thing a toast offers to do, such as undoing what it reports or showing details.
struct ToastAction {
    let title: String
    let run: @MainActor () -> Void
}

/// A short note at the bottom of the history pane that fades out by itself, for things worth knowing that need no answer, such as commits a rebase left out.
/// It may carry one action; it then stays a little longer, and the action is gone with the toast.
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

    func show(_ text: String, action: ToastAction? = nil) {
        generation += 1
        let current = generation
        view.text = text
        view.action = action.map { action in
            ToastAction(title: action.title) { [weak self] in
                self?.hide()
                action.run()
            }
        }
        view.isHidden = false
        if ScreenshotHarness.isActive { ScreenshotHarness.toastShown(view, text: text) }
        fade(to: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? Theme.Toast.duration : Theme.Toast.actionDuration)) { [weak self] in
            guard let self, current == generation else { return }
            hide()
        }
    }

    /// Fades the toast out now; a newer message cancels this.
    func hide() {
        generation += 1
        let current = generation
        fade(to: 0) { [weak self] in
            guard let self, current == generation else { return }
            view.isHidden = true
            view.action = nil
        }
    }

    private func fade(to alpha: CGFloat, then completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Toast.fade
            view.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }
}

/// A rounded, outlined pill with a glyph, one line of text and an optional action link; apart from the link it lets clicks through to the history below.
final class ToastView: NSView {
    private typealias M = Theme.Toast
    private let glyph = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) lazy var actionButton = LinkButton(target: self, action: #selector(runAction(_:)))
    private var actionHandler: (@MainActor () -> Void)?

    var action: ToastAction? {
        didSet {
            actionHandler = action?.run
            actionButton.isHidden = action == nil
            actionButton.attributedTitle = NSAttributedString(string: action?.title ?? "", attributes: [.font: Theme.bodyStrong, .foregroundColor: Theme.moss])
        }
    }

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
        actionButton.isHidden = true
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [glyph, label, actionButton])
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

    /// Only the action link takes clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !actionButton.isHidden, let hit = super.hitTest(point), hit === actionButton || hit.isDescendant(of: actionButton) else { return nil }
        return hit
    }

    /// The toast sits over the history, whose window is key anyway; a click on the link should act at once.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func runAction(_ sender: Any?) { actionHandler?() }

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
