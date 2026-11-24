import AppKit

/// A pane with nothing to show: a centred title with optional detail lines, and the bonsai drawing quietly at the lower right.
/// It takes the place of the content instead of lying behind it, never scrolls, and suits any empty pane.
final class EmptyStateView: NSView {
    struct Content: Equatable {
        var title: String
        /// One line each, cut in the middle when too long.
        var detail: [String] = []
        /// Paths, modes and other git values read best in monospace.
        var detailIsCode = false
        var toolTip: String?
        /// A button below the text, such as Retry after a failed read.
        var action: Action?

        struct Action: Equatable {
            var title: String
            var identifier: String
        }
    }

    /// Runs when the content's action button is pressed.
    var onAction: (() -> Void)?

    private typealias E = Theme.EmptyState
    private let art = BonsaiArtView()
    private let title = NSTextField(labelWithString: "")
    private let details = NSStackView()
    private let stack = NSStackView()
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(art)
        title.font = Theme.title
        title.textColor = Theme.ink
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        details.orientation = .vertical
        details.alignment = .centerX
        details.spacing = E.lineSpacing
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = E.titleGap
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(details)
        actionButton.bezelStyle = .push
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.isHidden = true
        stack.addArrangedSubview(actionButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: E.maximumTextWidth)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -E.lift),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Theme.Space.xl),
            preferredWidth,
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(_ content: Content) {
        title.stringValue = content.title
        toolTip = content.toolTip
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in content.detail {
            let field = NSTextField(labelWithString: line)
            field.font = content.detailIsCode ? Theme.mono : Theme.body
            field.textColor = Theme.inkMuted
            field.alignment = .center
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            details.addArrangedSubview(field)
            field.widthAnchor.constraint(lessThanOrEqualTo: details.widthAnchor).isActive = true
        }
        details.isHidden = content.detail.isEmpty
        actionButton.title = content.action?.title ?? ""
        actionButton.setAccessibilityIdentifier(content.action?.identifier)
        actionButton.isHidden = content.action == nil
    }

    /// The title and, when shown, the action button's title, for harness reports.
    var harnessSummary: String { actionButton.isHidden ? title.stringValue : "\(title.stringValue) [\(actionButton.title)]" }

    @objc private func performAction() {
        onAction?()
    }

    /// The drawing keeps its proportions: two thirds of the height, unless that would take more than half the width.
    override func layout() {
        super.layout()
        let aspect = BonsaiArtView.aspectRatio
        var height = bounds.height * E.artHeightShare
        height = min(height, bounds.width * E.artMaximumWidthShare / aspect)
        let width = height * aspect
        art.frame = CGRect(x: bounds.maxX - E.artInset - width, y: bounds.maxY - E.artInset - height, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Views no longer clip to their bounds, and the dirty rect may reach past them over the header.
        Theme.surface0.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// The bonsai in its bowl as line art, the same paths as `docs/design/icons/empty-state-bonsai.svg`, stroked at constant widths in a whisper of ink.
final class BonsaiArtView: NSView {
    private enum Weight { case fine, branch, trunk }

    /// SVG path data in the drawing's own coordinates; only absolute M, L, H, V, Q, C and Z.
    private static let strokes: [(Weight, String)] = [
        (.trunk, "M120 228V206C120 192 102 188 102 172V158C102 142 134 138 140 120C144 108 144 98 144 84"),
        (.branch, "M103 166C90 160 70 158 60 140"),
        (.branch, "M136 130C152 133 170 133 181 124"),
        (.fine, "M143 110C134 109 122 108 114 104"),
        (.fine, "M29.2 140L92.8 140Q102.5 140 95 132.8C95 123.8 78 123.8 78 132.8C78 120.5 61 120.5 61 132.8C61 120.5 44 120.5 44 132.8C44 123.8 27 123.8 27 132.8Q19.4 140 29.2 140Z"),
        (.fine, "M152.8 124L213.2 124Q222.2 124 215.2 117.4C215.2 109 199.1 109 199.1 117.4C199.1 106 183 106 183 117.4C183 106 166.9 106 166.9 117.4C166.9 109 150.8 109 150.8 117.4Q143.8 124 152.8 124Z"),
        (.fine, "M104 84L184 84Q195.2 84 186.3 75.8C186.3 65.2 169.4 65.2 169.4 75.8C169.4 65.2 152.5 65.2 152.5 75.8C152.5 61.5 135.5 61.5 135.5 75.8C135.5 65.2 118.6 65.2 118.6 75.8C118.6 65.2 101.7 65.2 101.7 75.8Q92.8 84 104 84Z"),
        (.fine, "M91.6 104L130.4 104Q137.2 104 132.2 99C132.2 92.8 118.1 92.8 118.1 99C118.1 90.5 103.9 90.5 103.9 99C103.9 92.8 89.8 92.8 89.8 99Q84.8 104 91.6 104Z"),
        (.fine, "M34 228H206"),
        (.fine, "M40 228L48 258Q50 264 56 264H184Q190 264 192 258L200 228"),
        (.fine, "M64 264V272M176 264V272"),
        (.fine, "M58 228C80 222 100 224 120 224C140 224 160 222 182 228"),
    ]

    private static let paths: [(Weight, CGPath)] = strokes.map { ($0.0, path(from: $0.1)) }
    private static let extent: CGRect = paths.reduce(CGRect.null) { $0.union($1.1.boundingBoxOfPath) }
    static var aspectRatio: CGFloat { extent.width / extent.height }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, !bounds.isEmpty else { return }
        typealias E = Theme.EmptyState
        // Half the widest stroke stays inside the bounds.
        let inset = E.artTrunkStroke / 2
        let scale = min((bounds.width - 2 * inset) / Self.extent.width, (bounds.height - 2 * inset) / Self.extent.height)
        var transform = CGAffineTransform(translationX: inset, y: inset).scaledBy(x: scale, y: scale).translatedBy(x: -Self.extent.minX, y: -Self.extent.minY)
        context.setStrokeColor(E.art.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for (weight, path) in Self.paths {
            guard let scaled = path.copy(using: &transform) else { continue }
            let width: CGFloat = switch weight {
            case .fine: E.artStroke
            case .branch: E.artBranchStroke
            case .trunk: E.artTrunkStroke
            }
            context.setLineWidth(width)
            context.addPath(scaled)
            context.strokePath()
        }
    }

    /// Enough of SVG path syntax for the drawing above.
    private static func path(from data: String) -> CGPath {
        let path = CGMutablePath()
        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = .whitespaces
        var current = CGPoint.zero
        func number() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
        func point() -> CGPoint { CGPoint(x: number(), y: number()) }
        while let command = scanner.scanCharacter() {
            switch command {
            case "M": current = point(); path.move(to: current)
            case "L": current = point(); path.addLine(to: current)
            case "H": current.x = number(); path.addLine(to: current)
            case "V": current.y = number(); path.addLine(to: current)
            case "Q":
                let control = point()
                current = point()
                path.addQuadCurve(to: current, control: control)
            case "C":
                let first = point()
                let second = point()
                current = point()
                path.addCurve(to: current, control1: first, control2: second)
            case "Z": path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
