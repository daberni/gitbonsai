import AppKit
import GitEngine

/// Harness switches for diffs, the file lists, the file context menu, the commit form and discarding.
@MainActor
extension ScreenshotHarness {
    /// `GITBONSAI_OPEN_FILE=<path>` with `GITBONSAI_OPEN_SOURCE=unstaged|staged|untracked` opens a file of the working directory, or of the selected commit without a source.
    /// `GITBONSAI_HUNK_ACTION=<n>` then stages or unstages hunk n.
    static func openDiff(on tab: RepositoryViewController) {
        guard let path = environment["GITBONSAI_OPEN_FILE"] else { return }
        let row = tab.history.selectedRow
        let source: DiffSource
        switch environment["GITBONSAI_OPEN_SOURCE"] {
        case "unstaged": source = .unstaged
        case "staged": source = .staged
        case "untracked": source = .untracked
        default:
            guard row >= 0 else { return }
            source = .commit(tab.viewModel.commits[row])
        }
        tab.openFile(FileSelection(path: path, originalPath: nil, source: source))
        if let hunk = environment["GITBONSAI_HUNK_ACTION"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tab.diff.runHunkAction(hunk) }
        }
        driveDiffHeader(on: tab)
    }

    // MARK: Diff mode

    /// `GITBONSAI_CLICK_DIFF_CLOSE=1` clicks the diff's close button with a real click and prints whether the graph is back.
    static func clickDiffClose(on tab: RepositoryViewController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = tab.view.window else { return }
            let close = tab.diff.header.close
            let before = tab.diff.view.window != nil && !tab.diff.view.isHiddenOrHasHiddenAncestor
            click(in: window, at: close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let after = tab.diff.view.window != nil && !tab.diff.view.isHiddenOrHasHiddenAncestor
                FileHandle.standardError.write(Data("diff shown before close click: \(before), after: \(after)\n".utf8))
            }
        }
    }

    /// `GITBONSAI_CLICK_DIFF_MODE=diff|file` clicks that half of the "Diff | Datei" toggle, then `GITBONSAI_DIFF_NEXT=<n>` clicks ↓ n times; both with real mouse events, printing the numbers of the top and bottom line after each step.
    static func driveDiffHeader(on tab: RepositoryViewController) {
        let environment = environment
        let mode = environment["GITBONSAI_CLICK_DIFF_MODE"].flatMap(DiffMode.init)
        let jumps = environment["GITBONSAI_DIFF_NEXT"].flatMap(Int.init) ?? 0
        if environment["GITBONSAI_CLICK_DIFF_CLOSE"] == "1" { return clickDiffClose(on: tab) }
        guard mode != nil || jumps > 0 else { return }
        func report(_ step: String) { FileHandle.standardError.write(Data("\(step): top line \(tab.diff.topLineNumbers), bottom line \(tab.diff.bottomLineNumbers)\n".utf8)) }
        func jump(_ remaining: Int) {
            guard remaining > 0, let window = tab.view.window else { return }
            let next = tab.diff.header.next
            click(in: window, at: next.convert(CGPoint(x: next.bounds.midX, y: next.bounds.midY), to: nil))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                report("after ↓")
                jump(remaining - 1)
            }
        }
        // The diff loads asynchronously and the toggle shows once it is there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = tab.view.window else { return }
            guard let mode else { return jump(jumps) }
            let modes = tab.diff.header.modes
            guard !modes.isHidden, let index = DiffMode.allCases.firstIndex(of: mode) else {
                FileHandle.standardError.write(Data("no diff mode toggle\n".utf8))
                return
            }
            let segment = modes.bounds.width / CGFloat(DiffMode.allCases.count)
            click(in: window, at: modes.convert(CGPoint(x: segment * (CGFloat(index) + 0.5), y: modes.bounds.midY), to: nil))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                report("clicked \(mode.title)")
                jump(jumps)
            }
        }
    }

    /// `GITBONSAI_CLICK_FILE=<n>` clicks the n-th file in the detail panel with real mouse events and reports whether its diff opened.
    static func clickFile(on tab: RepositoryViewController) {
        guard let index = environment["GITBONSAI_CLICK_FILE"].flatMap(Int.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = tab.view.window else { return }
            var rows: [FileRowView] = []
            func collect(_ view: NSView) {
                if let row = view as? FileRowView { rows.append(row) }
                view.subviews.forEach(collect)
            }
            collect(window.contentView!)
            guard rows.indices.contains(index) else {
                FileHandle.standardError.write(Data("only \(rows.count) file rows\n".utf8))
                return
            }
            let row = rows[index]
            let point = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let hit = window.contentView?.superview?.hitTest(point).map { "\(type(of: $0))" } ?? "nothing"
            click(in: window, at: point)
            // The release is still queued; the result is there once it has been handled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let opened = tab.diff.selection?.path
                FileHandle.standardError.write(Data("clicked \(row.model.selection.path) (hit \(hit)), diff shows \(opened ?? "nothing")\n".utf8))
            }
        }
    }

    /// `GITBONSAI_FILE_KEYS=down,down,up` presses arrow keys through the window after `GITBONSAI_CLICK_FILE` and reports the history row and the diff after each.
    static func pressFileKeys(on tab: RepositoryViewController) {
        guard let keys = environment["GITBONSAI_FILE_KEYS"]?.split(separator: ",").map(String.init), !keys.isEmpty else { return }
        for (step, key) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + 0.4 * Double(step)) {
                guard let window = tab.view.window else { return }
                let arrow: (scalar: Int, code: UInt16)? = switch key {
                case "up": (NSUpArrowFunctionKey, 126)
                case "down": (NSDownArrowFunctionKey, 125)
                default: nil
                }
                guard let arrow, let scalar = UnicodeScalar(arrow.scalar) else { return }
                let characters = String(Character(scalar))
                let responder = window.firstResponder.map { "\(type(of: $0))" } ?? "nothing"
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: arrow.code) {
                    window.sendEvent(event)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let shown = tab.diff.selection.map { selection in
                        if case .commit(let commit) = selection.source { return "\(selection.path) (commit \(commit.shortID))" }
                        return "\(selection.path) (\(selection.source))"
                    }
                    FileHandle.standardError.write(Data("key \(key) to \(responder): history row \(tab.history.selectedRow), diff shows \(shown ?? "nothing")\n".utf8))
                }
            }
        }
    }

    /// `GITBONSAI_COMMIT_SUBJECT` and `GITBONSAI_COMMIT_BODY` fill the commit form, `GITBONSAI_AMEND=1` ticks amend,
    /// `GITBONSAI_COMMIT_RUN=1` clicks the commit button.
    static func fillCommit(on tab: RepositoryViewController) {
        let form = tab.commitController.form
        if environment["GITBONSAI_AMEND"] == "1" { form.pressAmend() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let subject = environment["GITBONSAI_COMMIT_SUBJECT"] { form.subjectText = subject }
            if let body = environment["GITBONSAI_COMMIT_BODY"] { form.bodyText = body.replacingOccurrences(of: "\\n", with: "\n") }
            form.onEdit?()
            if environment["GITBONSAI_COMMIT_RUN"] == "1" { form.pressCommit() }
        }
    }


    // MARK: Discarding

    /// `GITBONSAI_CLICK_HUNK_DISCARD=<n>` clicks "Hunk verwerfen" of hunk n in the open diff, `GITBONSAI_HOVER_FILE=<n>` moves the mouse onto file row n,
    /// `GITBONSAI_CLICK_FILE_DISCARD=<n>` also clicks that row's discard button; all with real mouse events through the window.
    static func discard(on tab: RepositoryViewController, attempt: Int = 0) {
        let environment = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let window = tab.view.window else { return }
            if let index = environment["GITBONSAI_CLICK_HUNK_DISCARD"].flatMap(Int.init) {
                // The diff loads asynchronously; try again until its hunk rows are there.
                if views(of: DiffHunkView.self, in: window).count <= index, attempt < 10 {
                    discard(on: tab, attempt: attempt + 1)
                    return
                }
                let hunks = views(of: DiffHunkView.self, in: window).sorted { $0.convert(CGPoint.zero, to: nil).y > $1.convert(CGPoint.zero, to: nil).y }
                guard hunks.indices.contains(index), !hunks[index].discard.isHidden else {
                    FileHandle.standardError.write(Data("no discard button on hunk \(index) of \(hunks.count)\n".utf8))
                    return
                }
                let button = hunks[index].discard
                click(in: window, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            }
            let rowIndex = environment["GITBONSAI_CLICK_FILE_DISCARD"].flatMap(Int.init) ?? environment["GITBONSAI_HOVER_FILE"].flatMap(Int.init)
            if let rowIndex {
                let rows = views(of: FileRowView.self, in: window)
                guard rows.indices.contains(rowIndex), let discardIndex = rows[rowIndex].model.actions.firstIndex(of: .discard) else {
                    FileHandle.standardError.write(Data("no discard button on file row \(rowIndex) of \(rows.count)\n".utf8))
                    return
                }
                let row = rows[rowIndex]
                let rect = row.actionRect(discardIndex)
                let point = row.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
                // Tracking areas follow the real cursor only, so the move goes to the view under the point the way tracking would deliver it.
                if let moved = mouseEvent(.mouseMoved, at: point, in: window) { window.contentView?.superview?.hitTest(point)?.mouseMoved(with: moved) }
                if environment["GITBONSAI_CLICK_FILE_DISCARD"] != nil { click(in: window, at: point) }
            }
        }
    }

    /// The confirmation sheet for discarding. `GITBONSAI_DISCARD_ANSWER=confirm|cancel` clicks its button with real mouse events;
    /// without an answer `GITBONSAI_SHEET_SCREENSHOT=<path>` writes the sheet to a PNG while it is up.
    static func answerDiscardSheet(_ alert: NSAlert) {
        guard outputPath != nil else { return }
        let environment = environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let sheet = alert.window
            FileHandle.standardError.write(Data("discard sheet: \(alert.messageText) — \(alert.informativeText)\n".utf8))
            switch environment["GITBONSAI_DISCARD_ANSWER"] {
            case "confirm", "cancel":
                let button = alert.buttons[environment["GITBONSAI_DISCARD_ANSWER"] == "confirm" ? 0 : 1]
                click(in: sheet, at: button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            default:
                guard let path = environment["GITBONSAI_SHEET_SCREENSHOT"], let view = sheet.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
                // The sheet's glass and vibrant text blend with what lies behind them; on an empty bitmap they vanish, so a window background goes underneath.
                sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    NSColor.windowBackgroundColor.setFill()
                    view.bounds.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                view.displayIgnoringOpacity(view.bounds, in: context)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: File context menu

    /// `GITBONSAI_FILE_MENU=<n>` asks file row n for the menu a right click would open and prints its entries, ⌥ alternates marked, without showing it on screen.
    /// `GITBONSAI_FILE_MENU_PICK=<title>` then chooses an entry; confirmations are answered by `GITBONSAI_CONFIRM` and rendered by `GITBONSAI_SHEET_SHOT`.
    static func fileMenu(on tab: RepositoryViewController, attempt: Int = 0) {
        guard let index = environment["GITBONSAI_FILE_MENU"].flatMap(Int.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let window = tab.view.window else { return }
            // A commit's file list loads asynchronously; try again until the row is there.
            let rows = views(of: FileRowView.self, in: window)
            guard rows.indices.contains(index) else {
                if attempt < 10 { return fileMenu(on: tab, attempt: attempt + 1) }
                FileHandle.standardError.write(Data("only \(rows.count) file rows\n".utf8))
                return
            }
            let row = rows[index]
            let point = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), let menu = row.menu(for: event) else {
                FileHandle.standardError.write(Data("file row \(index) has no menu\n".utf8))
                return
            }
            let entries = menu.items.map { item in item.isSeparatorItem ? "|" : item.isAlternate ? "⌥ \(item.title)" : item.title }
            FileHandle.standardError.write(Data("file menu \(row.model.selection.path): \(entries.joined(separator: "; "))\n".utf8))
            if let pick = environment["GITBONSAI_FILE_MENU_PICK"] { choose(pick, in: menu) }
        }
    }
}
