import AppKit
import GitEngine

/// Harness switches for the conflict view.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_OPEN_CONFLICT=<path>` opens the conflict view of that unmerged file of the working directory.
    /// `GITBONSAI_CONFLICT_SCRIPT=<step>;…` then drives it, half a second per step, with real clicks and key equivalents. In the history pane:
    /// `link:<change>:ours|theirs|both|merge|undo` (a link of the action row above a conflict, counted from 0), `next`, `previous` (the header's arrows), `key:next|previous|escape` (⌥⌘↓/⌥⌘↑/Esc),
    /// `resolve` (Mark resolved), `action:<n>` (button n of a whole-file choice), `continue` (the banner's Continue), `window` (Resolve in merge window…).
    /// In the open merge window: `take:<change>:ours|theirs` and `ignore:<change>:ours|theirs` (gutter buttons), `wand` (Merge simple conflicts), `base` (Show base), `wresolve` (its Mark resolved), `wshot:<png>` (the window), `wclose`.
    /// Always: `print` (the pane, header, scroll position, current change, each change's state, the merge window, the banner and its Continue), `shot:<png>`, `wait:<seconds>`.
    static func driveConflicts(on tab: RepositoryViewController) {
        let environment = environment
        if let path = environment["GITBONSAI_OPEN_CONFLICT"] {
            tab.openFile(FileSelection(path: path, originalPath: nil, source: .unstaged))
        }
        guard let script = environment["GITBONSAI_CONFLICT_SCRIPT"] else { return }
        let steps = script.split(separator: ";").map(String.init)
        runConflictStep(steps[...], on: tab, after: 0.8)
    }

    private static func runConflictStep(_ steps: ArraySlice<String>, on tab: RepositoryViewController, after delay: Double) {
        guard let step = steps.first else { return }
        after(delay) {
            let wait = performConflictStep(step, on: tab)
            runConflictStep(steps.dropFirst(), on: tab, after: wait)
        }
    }

    /// Runs one step and returns how long to wait before the next.
    private static func performConflictStep(_ step: String, on tab: RepositoryViewController) -> Double {
        let parts = step.split(separator: ":", maxSplits: 2).map(String.init)
        let conflicts = tab.conflicts!
        guard let window = tab.view.window else { return 0.5 }
        func report(_ text: String) { FileHandle.standardError.write(Data("conflict \(step): \(text)\n".utf8)) }
        func clickCenter(of view: NSView) { click(in: window, at: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)) }
        let mergeWindow = conflicts.path.flatMap { conflicts.windows[$0] }
        func clickInWindow(_ view: NSView) {
            guard let target = view.window else { return report("not in a window") }
            click(in: target, at: view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        }
        switch parts[0] {
        case "link":
            let kind = parts.count > 2 ? parts[2] : ""
            let link = switch kind {
            case "merge": "merge/\(parts[1])"
            case "undo": "reopen/\(parts[1])"
            default: "take/\(parts.count > 1 ? parts[1] : "")/\(kind)"
            }
            let column = conflicts.unified.column
            guard let point = column.center(ofLink: link) else { report("no link \(link)"); break }
            column.scrollToVisible(NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
            click(in: window, at: column.convert(point, to: nil))
        case "window": clickCenter(of: conflicts.header.resolve)
        case "take", "ignore":
            let take = parts[0] == "take"
            let side: ConflictSide = parts.count > 2 && parts[2] == "theirs" ? .theirs : .ours
            guard let mergeWindow else { report("no merge window"); break }
            let gutter = side == .ours ? mergeWindow.columns.oursGutter : mergeWindow.columns.theirsGutter
            guard let change = parts.count > 1 ? Int(parts[1]) : nil, let action = gutter.actions.first(where: { $0.change == change && $0.take == take }) else { report("no such button"); break }
            clickInWindow(action.button)
        case "wand": if let mergeWindow { clickInWindow(mergeWindow.header.mergeWords) } else { report("no merge window") }
        case "base": if let mergeWindow { clickInWindow(mergeWindow.header.showBase) } else { report("no merge window") }
        case "wresolve": if let mergeWindow { clickInWindow(mergeWindow.header.markResolved) } else { report("no merge window") }
        case "wclose": mergeWindow?.close()
        case "wshot":
            guard parts.count > 1, let view = mergeWindow?.window?.contentView?.superview else { report("no merge window"); break }
            writePNG(of: view, to: parts[1])
            report("wrote \(parts[1])")
        case "next": clickCenter(of: conflicts.header.next)
        case "previous": clickCenter(of: conflicts.header.previous)
        case "key" where parts.count > 1 && parts[1] == "escape":
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            let handled = event.map { window.performKeyEquivalent(with: $0) } ?? false
            report("handled \(handled)")
        case "key":
            let key = parts.count > 1 && parts[1] == "previous" ? NSUpArrowFunctionKey : NSDownArrowFunctionKey
            let characters = String(Character(UnicodeScalar(UInt16(key))!))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option, .function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key == NSUpArrowFunctionKey ? 126 : 125)
            let handled = event.map { window.performKeyEquivalent(with: $0) } ?? false
            report("handled \(handled), current \(conflicts.session?.current ?? -1)")
        case "resolve": clickCenter(of: conflicts.header.markResolved)
        case "action":
            guard let index = parts.count > 1 ? Int(parts[1]) : nil, let buttons = conflicts.choiceView?.buttons, buttons.indices.contains(index) else { report("no such action"); break }
            clickCenter(of: buttons[index].1)
        case "continue": clickCenter(of: tab.operationBanner.view.continueButton)
        case "print": report(conflictSummary(of: tab))
        case "shot":
            guard parts.count > 1, let view = window.contentView?.superview else { break }
            writePNG(of: view, to: parts[1])
            report("wrote \(parts[1])")
        case "wait": return parts.count > 1 ? Double(parts[1]) ?? 0.5 : 0.5
        default: report("unknown step")
        }
        return 0.5
    }

    private static func conflictSummary(of tab: RepositoryViewController) -> String {
        let conflicts = tab.conflicts!
        let shown = tab.historyPane.current === conflicts.view ? "conflict view of \(conflicts.path ?? "-")" : tab.historyPane.current === tab.diff.view ? "diff" : "graph"
        let changes = conflicts.session.map { session in
            let resolution = session.resolution
            return resolution.states.indices.map { index -> String in
                let state = resolution.states[index]
                let value = !resolution.isResolved(index) ? "open" : state.merged != nil ? "merged" : state.taken.isEmpty ? "base" : state.taken.map { $0 == .ours ? "ours" : "theirs" }.joined(separator: "+")
                return "\(index)=\(value)"
            }.joined(separator: ",")
        } ?? ""
        let mergeWindow = conflicts.path.flatMap { conflicts.windows[$0] }
        let windowState = mergeWindow.map { "merge window [\($0.header.summary) | \($0.columns.resultCaption)]" } ?? "no merge window"
        let banner = tab.operationBanner.view
        let open = tab.viewModel.status?.conflicted.map(\.path).joined(separator: ",") ?? "-"
        return "\(shown) | \(conflicts.header.summary) | scrolled to \(conflicts.scrollOffset) | current \(conflicts.session?.current ?? -1) changes [\(changes)] | \(windowState) | unmerged [\(open)] | banner \(banner.isHidden ? "hidden" : "“\(banner.text)” continue=\(banner.continueButton.isEnabled)")"
    }
}
