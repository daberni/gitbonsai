import AppKit
import GitEngine

/// The round picture of an author or committer in the detail panel, with the generated fallback until the avatar is known.
final class AvatarView: NSView {
    /// Whose picture to show, as the avatar store looks it up.
    struct Source {
        let email: String
        let commit: String
        let repository: Repository
        let store: AvatarStore
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
        if let context = NSGraphicsContext.current?.cgContext {
            if let image = source.store.image(email: source.email, commit: source.commit, in: source.repository) {
                AvatarDrawing.draw(image, in: bounds, ring: Theme.Stroke.strand, context: context)
            } else {
                AvatarFallbackDrawing.draw(email: source.email, initials: initials, style: source.store.fallbackStyle, font: Theme.initials, in: bounds, ring: Theme.Stroke.strand, context: context)
            }
        }
        ring.setStroke(); circle.lineWidth = Theme.Stroke.strand; circle.stroke()
    }
}
