import AppKit
import GitEngine

/// The round picture of an author or committer in the detail panel, with the initials until the avatar is known.
final class AvatarView: NSView {
    /// Whose picture to show, as the avatar store looks it up.
    struct Source {
        let email: String
        let commit: String
        let repository: Repository
    }

    private let initials: String
    private let ring: NSColor
    private let source: Source
    private var observer: NSObjectProtocol?

    init(initials: String, ring: NSColor, source: Source) {
        self.initials = initials
        self.ring = ring
        self.source = source
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.Detail.avatar, height: Theme.Detail.avatar))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Theme.Detail.avatar), heightAnchor.constraint(equalToConstant: Theme.Detail.avatar)])
        observer = NotificationCenter.default.addObserver(forName: AvatarStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: Theme.Stroke.strand / 2, dy: Theme.Stroke.strand / 2))
        Theme.surface2.setFill(); circle.fill()
        if let image = AvatarStore.shared.image(email: source.email, commit: source.commit, in: source.repository), let context = NSGraphicsContext.current?.cgContext {
            AvatarDrawing.draw(image, in: bounds, ring: Theme.Stroke.strand, context: context)
        } else {
            let text = NSAttributedString(string: initials, attributes: [.font: Theme.initials, .foregroundColor: Theme.inkMuted])
            let size = text.size()
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
        ring.setStroke(); circle.lineWidth = Theme.Stroke.strand; circle.stroke()
    }
}
