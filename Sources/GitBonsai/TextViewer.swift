import AppKit
import CodeEditTextView
import TextViewerModel

/// The read-only text viewer every file view shares: monospaced text, a gutter of line numbers and an optional side column, line decorations from the caller and syntax colours.
/// CodeEditTextView lays out and draws only the visible lines; the gutter and the washes behind the text are views of their own that follow its line positions, so they never take part in selection or copy.
@MainActor
final class TextViewer: NSView {
    struct Content {
        var document: TextDocument
        /// nil shows plain text.
        var language: SyntaxLanguage?
        /// Looks of single lines by their index; lines without an entry are drawn plain.
        var decorations: [Int: TextViewerDecoration] = [:]
        /// Drawn left of the text in place of plain line numbers when set, such as a diff's old and new numbers.
        var sideColumn: TextViewerSideColumn?
    }

    /// The selection as line and column ranges, after every change.
    var onSelectionChange: (([TextSelection]) -> Void)?

    let textView: ViewerTextView
    let scroll: NSScrollView
    let gutter = TextViewerGutter()
    let backdrop = TextViewerBackdrop()
    let findBar = TextViewerFindBar()
    private var findBarHeight: NSLayoutConstraint?
    private var gutterWidth: NSLayoutConstraint?
    private(set) var content: Content?
    var highlighting: TextViewerHighlighting?
    var find: TextFind?
    var currentMatch: Int?

    /// `nested` passes vertical scrolling on to an enclosing scroll view, for a viewer that is as tall as its text inside a stack of files.
    init(nested: Bool = false) {
        textView = ViewerTextView(string: "", font: Theme.mono, textColor: Theme.ink, lineHeightMultiplier: Self.lineHeightMultiplier, wrapLines: false, isEditable: false, isSelectable: false, letterSpacing: 1)
        scroll = nested ? NestedScrollView() : NSScrollView()
        super.init(frame: .zero)
        textView.viewer = self
        textView.edgeInsets = HorizontalEdgeInsets(left: Theme.TextViewer.textInset, right: Theme.TextViewer.textInset)
        textView.selectionManager.highlightSelectedLine = false
        textView.setAccessibilityIdentifier("textViewer.text")
        scroll.documentView = textView
        scroll.hasVerticalScroller = !nested
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        gutter.viewer = self
        backdrop.viewer = self
        findBar.viewer = self
        findBar.isHidden = true
        arrangeViews()
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // Selection stays off until clicks behave as in a native text view; CodeEditTextView ignores a single click in read-only text.
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: TextSelectionManager.selectionChangedNotification, object: textView.selectionManager)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func arrangeViews() {
        for view in [backdrop, gutter, scroll, findBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        let gutterWidth = gutter.widthAnchor.constraint(equalToConstant: Theme.TextViewer.lineNumberColumn)
        self.findBarHeight = findBarHeight
        self.gutterWidth = gutterWidth
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topAnchor),
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            findBarHeight,
            gutter.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutterWidth,
            scroll.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// CodeEditTextView sets a line's height from the font times this factor.
    private static var lineHeightMultiplier: CGFloat {
        let font = Theme.mono
        return Theme.TextViewer.lineHeight / (font.ascender - font.descender + font.leading)
    }

    /// ⌘F, ⌘G, ⇧⌘G and ⌘L belong to the viewer while its text or find bar has the focus; elsewhere ⌘F stays the commit search.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === textView || findBar.hasFocus else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("f", .command):
            showFindBar(.find)
        case ("g", .command):
            findNext(forward: true)
        case ("g", [.command, .shift]):
            findNext(forward: false)
        case ("l", .command):
            showFindBar(.goToLine)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // MARK: Content

    /// Shows a new text; selection, find and highlighting start over, and the view goes back to the top left.
    func show(_ content: Content) {
        self.content = content
        highlighting?.cancel()
        highlighting = nil
        find = nil
        currentMatch = nil
        textView.string = content.document.text
        fitWidth(to: content.document)
        applyStruckMarks(content)
        gutterWidth?.constant = content.sideColumn?.width ?? Theme.TextViewer.lineNumberColumn
        textView.selectionManager.setSelectedRanges([])
        textView.layoutManager.setNeedsLayout()
        textView.needsLayout = true
        highlighting = TextViewerHighlighting(viewer: self, document: content.document, language: content.language)
        if !findBar.isHidden { findBar.searchAgain() }
        refresh()
    }

    /// Word diff marks that belong to one side only are struck through, in the text itself so the line keeps its width.
    private func applyStruckMarks(_ content: Content) {
        guard let storage = textView.textStorage else { return }
        let struck = content.decorations.flatMap { line, decoration in
            decoration.marks.filter(\.struck).map { mark in Self.range(of: mark.columns, inLine: line, of: content.document) }
        }
        guard !struck.isEmpty else { return }
        storage.beginEditing()
        for range in struck { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        storage.endEditing()
    }

    static func range(of columns: Range<Int>, inLine line: Int, of document: TextDocument) -> NSRange {
        let lineRange = document.range(ofLine: line)
        let start = min(columns.lowerBound, lineRange.length)
        let end = min(columns.upperBound, lineRange.length)
        return NSRange(location: lineRange.location + start, length: max(0, end - start))
    }

    /// Height of the whole text, for a viewer that grows with its content.
    var contentHeight: CGFloat { CGFloat(content?.document.lineCount ?? 0) * Theme.TextViewer.lineHeight }

    // MARK: Following the text

    @objc private func scrolled() { refresh() }

    func refresh() {
        gutter.needsDisplay = true
        backdrop.needsDisplay = true
        highlighting?.highlightVisibleLines()
    }

    /// The lines in view with their top and height in this view's coordinates; only the visible part of the text is laid out, so this is what the gutter and the washes draw.
    func visibleLines() -> [(line: Int, y: CGFloat, height: CGFloat)] {
        guard let layoutManager = textView.layoutManager, content != nil else { return [] }
        let visible = textView.visibleRect
        var result: [(Int, CGFloat, CGFloat)] = []
        // While the scroll view rubber-bands past either end, the visible rect reaches outside the text, where the lookup finds no line.
        let textHeight = max(textView.frame.height - 1, 0)
        var y = min(max(visible.minY, 0), textHeight)
        // Below the last line the lookup answers with the last line again; the loop ends there.
        while y < visible.maxY, let position = layoutManager.textLineForPosition(y), position.index > (result.last?.0 ?? -1) {
            let top = convert(NSPoint(x: 0, y: position.yPos), from: textView).y
            result.append((position.index, top, position.height))
            y = position.yPos + max(position.height, 1)
        }
        return result
    }

    /// The range of lines in view, for highlighting ahead of scrolling.
    var visibleLineRange: ClosedRange<Int>? {
        let lines = visibleLines()
        guard let first = lines.first?.line, let last = lines.last?.line else { return nil }
        return first...last
    }

    /// The rectangle of a character range within one line, in this view's coordinates.
    func rect(of range: NSRange) -> CGRect? {
        guard let start = textView.layoutManager.rectForOffset(range.location), let end = textView.layoutManager.rectForOffset(NSMaxRange(range)) else { return nil }
        let rect = CGRect(x: start.minX, y: start.minY, width: max(end.minX - start.minX, 0), height: start.height)
        return convert(rect, from: textView)
    }

    /// CodeEditTextView 0.12.1 never records its widest line, so the text view would stay as wide as the view and not scroll sideways; the longest line's width goes into the right inset instead, which the text view adds to its width.
    private func fitWidth(to document: TextDocument) {
        let text = document.text as NSString
        let longest = (0..<document.lineCount).map { document.range(ofLine: $0) }.max { $0.length < $1.length }
        let width = longest.map { NSAttributedString(string: text.substring(with: $0), attributes: textView.typingAttributes).size().width.rounded(.up) } ?? 0
        textView.edgeInsets = HorizontalEdgeInsets(left: Theme.TextViewer.textInset, right: Theme.TextViewer.textInset + width)
    }

    // MARK: Selection

    var selections: [TextSelection] {
        guard let document = content?.document else { return [] }
        return textView.selectionManager.textSelections.map { document.selection(of: $0.range) }
    }

    /// Every line any selection touches.
    var selectedLines: IndexSet {
        IndexSet(selections.flatMap { Array($0.lines) })
    }

    @objc private func selectionChanged() {
        backdrop.needsDisplay = true
        onSelectionChange?(selections)
    }

    /// Brings a line to the middle of the view and puts the caret at its start.
    func goToLine(_ line: Int) {
        guard let document = content?.document else { return }
        let range = document.range(ofLine: min(max(line, 0), document.lineCount - 1))
        textView.scrollToRange(range, center: true)
        window?.makeFirstResponder(textView)
    }

    /// Brings a line to the top of the view, for callers that jump between places such as the changes of a diff.
    func scrollToTop(line: Int, resettingSideways: Bool) {
        // A text set just now has no height until it is laid out.
        layoutSubtreeIfNeeded()
        let y = CGFloat(max(line, 0)) * Theme.TextViewer.lineHeight
        let maxY = max(0, textView.frame.height - scroll.contentView.bounds.height)
        let x = resettingSideways ? 0 : scroll.contentView.bounds.minX
        scroll.contentView.scroll(to: NSPoint(x: x, y: min(y, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        refresh()
    }

    /// The first line at the top of the view.
    var topLine: Int { Int(scroll.contentView.bounds.minY / Theme.TextViewer.lineHeight) }
    var topOffset: CGFloat { scroll.contentView.bounds.minY }
    var lastTopOffset: CGFloat { max(0, textView.frame.height - scroll.contentView.bounds.height) }

    // MARK: Find bar

    func showFindBar(_ mode: TextViewerFindBar.Mode) {
        findBar.isHidden = false
        findBarHeight?.constant = Theme.TextViewer.findBarHeight
        findBar.show(mode)
    }

    func hideFindBar() {
        findBar.isHidden = true
        findBarHeight?.constant = 0
        find = nil
        currentMatch = nil
        backdrop.needsDisplay = true
        window?.makeFirstResponder(textView)
    }

    /// Runs a search and selects the first match after the caret.
    func search(_ query: String) {
        guard let document = content?.document else { return }
        find = TextFind(query, in: document)
        currentMatch = nil
        findNext(forward: true, from: textView.selectionManager.textSelections.first?.range.location ?? 0, inclusive: true)
        findBar.showCount(find?.matches.count ?? 0, current: currentMatch)
    }

    func findNext(forward: Bool) {
        let current = currentMatch.flatMap { find?.matches[$0].location } ?? textView.selectionManager.textSelections.first?.range.location ?? 0
        findNext(forward: forward, from: current, inclusive: false)
    }

    private func findNext(forward: Bool, from offset: Int, inclusive: Bool) {
        guard let find, !find.matches.isEmpty else {
            if find != nil, !(find?.query.isEmpty ?? true) { NSSound.beep() }
            backdrop.needsDisplay = true
            return
        }
        let index = forward ? find.next(after: inclusive ? offset - 1 : offset, forward: true) : find.next(after: offset, forward: false)
        guard let index else { return }
        currentMatch = index
        let range = find.matches[index]
        textView.scrollToRange(range, center: true)
        findBar.showCount(find.matches.count, current: index)
        backdrop.needsDisplay = true
    }
}

/// How the caller wants one line to look: washes behind it and in the gutter, marked parts and markers for what is not visible.
struct TextViewerDecoration {
    struct Mark {
        /// UTF-16 columns of the line.
        let columns: Range<Int>
        let tint: NSColor
        /// Only the other side has this text, as in a word diff.
        var struck = false
    }

    var wash: NSColor?
    var gutterWash: NSColor?
    var marks: [Mark] = []
    /// Faint markers for tabs, trailing spaces and characters without a glyph.
    var showsInvisibles = false
    /// The line ended with CR LF, drawn as `␍` while invisibles show.
    var carriageReturn = false
    /// No newline follows the line.
    var missingNewline = false
}

/// A column left of the text that draws something of its own for every line, such as a diff's old and new numbers or blame.
@MainActor
protocol TextViewerSideColumn: AnyObject {
    var width: CGFloat { get }
    /// Draws one line's part of the column; `rect` is that line's row in the gutter.
    func draw(line: Int, in rect: CGRect)
}
