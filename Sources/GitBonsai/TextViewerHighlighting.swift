import AppKit
import TextViewerModel

/// Syntax colours for one text: tree-sitter parses it off the main thread once, then the lines in view and a margin around them are coloured as they come into view.
/// The text shows plain at once; colours follow without blocking scrolling.
@MainActor
final class TextViewerHighlighting {
    private weak var viewer: TextViewer?
    private let document: TextDocument
    private var highlighter: SyntaxHighlighter?
    private var parse: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    /// Lines whose colours are in the text storage.
    private var coloured = IndexSet()

    init(viewer: TextViewer, document: TextDocument, language: SyntaxLanguage?) {
        self.viewer = viewer
        self.document = document
        guard let language else { return }
        parse = Task { [weak self] in
            let interval = Signposts.begin("textViewer.highlight", language.rawValue)
            let highlighter = await Task.detached(priority: .userInitiated) { await SyntaxHighlighter.make(for: document, language: language) }.value
            interval.end(highlighter == nil ? "plain" : "parsed")
            guard let self, !Task.isCancelled else { return }
            self.highlighter = highlighter
            highlightVisibleLines()
        }
    }

    func cancel() {
        parse?.cancel()
        pending?.cancel()
    }

    /// Colours the lines in view plus a margin, skipping lines already coloured; one request runs at a time and the latest scroll position wins.
    func highlightVisibleLines() {
        guard let highlighter, let viewer, let visible = viewer.visibleLineRange, pending == nil else { return }
        let margin = Theme.TextViewer.highlightMargin
        let wanted = max(0, visible.lowerBound - margin)...min(document.lineCount - 1, visible.upperBound + margin)
        let missing = IndexSet(integersIn: wanted).subtracting(coloured)
        guard let first = missing.first, let last = missing.last else { return }
        let range = NSRange(location: document.lineStarts[first], length: NSMaxRange(document.range(ofLine: last)) - document.lineStarts[first])
        pending = Task { [weak self] in
            let spans = await highlighter.spans(in: range)
            guard let self, !Task.isCancelled else { return }
            apply(spans, in: range)
            coloured.insert(integersIn: first...last)
            pending = nil
            highlightVisibleLines()
        }
    }

    private func apply(_ spans: [SyntaxSpan], in range: NSRange) {
        guard let storage = viewer?.textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        for span in spans {
            let clipped = NSIntersectionRange(span.range, range)
            guard clipped.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: Theme.Syntax.color(span.token), range: clipped)
        }
        storage.endEditing()
        viewer?.textView.needsDisplay = true
    }
}
