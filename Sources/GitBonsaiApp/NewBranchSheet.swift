import AppKit
import GitEngine

/// What the "New Branch" sheet asks git to do.
struct NewBranchRequest: Equatable {
    enum Follow: Equatable {
        /// Only creates the branch.
        case stay
        /// Switches to it in the current folder.
        case checkout
        /// Checks it out in a new worktree at this path.
        case worktree(String)
    }

    let name: String
    let start: String
    let follow: Follow
}

/// The "New Branch" sheet: a window of its own, run as a sheet on the repository window, with `NewBranchViewController` as its content.
@MainActor
final class NewBranchSheet {
    let window: SheetWindow
    let form: NewBranchViewController

    init(form: NewBranchViewController) {
        self.form = form
        window = SheetWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: Theme.NewBranch.width, height: Theme.NewBranch.width)), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        window.contentViewController = form
        window.title = String(localized: "branch.new.title", defaultValue: "New Branch", bundle: .module, comment: "Title of the sheet that creates a branch.")
        window.onCancel = { [weak form] in form?.cancel() }
        window.onReturn = { [weak form] in form?.confirm() }
        form.onFinish = { [weak self] request in self?.finish(request) }
        form.onResize = { [weak self] in self?.fitToContent() }
    }

    private var request: NewBranchRequest?

    /// Shows the sheet on `parent` and waits for the answer; nil when it was cancelled.
    func run(on parent: NSWindow) async -> NewBranchRequest? {
        fitToContent()
        window.initialFirstResponder = form.nameInput.field
        let response = await withCheckedContinuation { continuation in
            parent.beginSheet(window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? request : nil
    }

    private func finish(_ request: NewBranchRequest?) {
        self.request = request
        window.sheetParent?.endSheet(window, returnCode: request == nil ? .cancel : .OK)
    }

    /// The sheet takes the height its form needs; its top edge stays where it is.
    private func fitToContent() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: false)
    }
}

/// A sheet window that answers Esc and ⏎ itself when no control took the key, wherever the focus is.
/// Tab follows its controls top to bottom and left to right; setting `initialFirstResponder` would otherwise leave it without a key view loop.
final class SheetWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        autorecalculatesKeyViewLoop = true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }
}
