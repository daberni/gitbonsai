import AppKit
import GitEngine

/// Harness switches for diffs, the file lists, the file context menu, the commit form and discarding.
@MainActor
extension ScreenshotHarness {
    /// The file rows on screen from top to bottom; the table reuses row views, so their order among the subviews says nothing.
    static func fileRows(in window: NSWindow) -> [FileRowView] {
        views(of: FileRowView.self, in: window)
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .sorted { $0.convert(CGPoint.zero, to: nil).y > $1.convert(CGPoint.zero, to: nil).y }
    }

    /// The context menu a right click on `row` opens; the file table builds it, not the row.
    static func fileMenu(of row: FileRowView, for event: NSEvent) -> NSMenu? {
        var view: NSView? = row
        while let current = view, !(current is NSTableView) { view = current.superview }
        return view?.menu(for: event)
    }

    /// `GITBONSAI_OPEN_FILE=<path>` with `GITBONSAI_OPEN_SOURCE=unstaged|staged|untracked` opens a file of the working directory, or of the selected commit without a source.
    /// `GITBONSAI_PRINT_DIFF_HEADER=1` prints the change letter, the path and its tooltip once the diff is shown.
    /// `GITBONSAI_OPEN_ORIGINAL=<path>` names the path before a rename or copy, as the file lists pass it.
    /// `GITBONSAI_HUNK_ACTION=<n>` then stages or unstages hunk n; `GITBONSAI_WINDOW_WIDTH=<points>` first resizes the window.
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
        if let width = environment["GITBONSAI_WINDOW_WIDTH"].flatMap(Double.init), let window = tab.view.window {
            window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: width, height: window.frame.height)), display: true)
        }
        tab.openFile(FileSelection(path: path, originalPath: environment["GITBONSAI_OPEN_ORIGINAL"], source: source))
        if let hunk = environment["GITBONSAI_HUNK_ACTION"].flatMap(Int.init) {
            after(0.3) { tab.diff.runHunkAction(hunk) }
        }
        driveDiffHeader(on: tab)
        driveImageDiff(on: tab)
        scrollDiffThenOpenFile(on: tab)
        if environment["GITBONSAI_PRINT_DIFF_HEADER"] == "1" {
            after(0.6) { FileHandle.standardError.write(Data("diff header: \(tab.diff.header.summary)\n".utf8)) }
        }
    }

    /// `GITBONSAI_DIFF_SCROLL_THEN_FILE=<x>,<y>,<n>` scrolls the open diff to that offset, then clicks the n-th file in the detail panel with a real click; the offset is printed after each step.
    static func scrollDiffThenOpenFile(on tab: RepositoryViewController) {
        let parts = environment["GITBONSAI_DIFF_SCROLL_THEN_FILE"]?.split(separator: ",").compactMap { Double($0) } ?? []
        guard parts.count == 3 else { return }
        func report(_ step: String) {
            let origin = tab.diff.scroll.contentView.bounds.origin
            FileHandle.standardError.write(Data("\(step): \(tab.diff.selection?.path ?? "no diff") at x \(Int(origin.x)), y \(Int(origin.y)), top line \(tab.diff.topLineNumbers)\n".utf8))
        }
        after(0.6) {
            let clip = tab.diff.scroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: CGPoint(x: parts[0], y: parts[1]), size: clip.bounds.size)).origin)
            tab.diff.scroll.reflectScrolledClipView(clip)
            report("scrolled")
            guard let window = tab.view.window else { return }
            let rows = fileRows(in: window)
            guard rows.indices.contains(Int(parts[2])) else {
                FileHandle.standardError.write(Data("only \(rows.count) file rows\n".utf8))
                return
            }
            let row = rows[Int(parts[2])]
            click(in: window, at: row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil))
            after(0.6) { report("opened another file") }
        }
    }

    // MARK: Diff mode

    /// `GITBONSAI_CLICK_DIFF_CLOSE=1` clicks the diff's close button with a real click and prints whether the graph is back.
    static func clickDiffClose(on tab: RepositoryViewController) {
        after(0.6) {
            guard let window = tab.view.window else { return }
            let close = tab.diff.header.close
            let before = tab.diff.view.window != nil && !tab.diff.view.isHiddenOrHasHiddenAncestor
            click(in: window, at: close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil))
            after(0.3) {
                let after = tab.diff.view.window != nil && !tab.diff.view.isHiddenOrHasHiddenAncestor
                FileHandle.standardError.write(Data("diff shown before close click: \(before), after: \(after)\n".utf8))
            }
        }
    }

    /// `GITBONSAI_CLICK_DIFF_MODE=diff|file` clicks that half of the "Diff | Whole file" toggle, then `GITBONSAI_DIFF_NEXT=<n>` clicks ↓ n times; both with real mouse events, printing the numbers of the top and bottom line after each step.
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
            after(0.2) {
                report("after ↓")
                jump(remaining - 1)
            }
        }
        // The diff loads asynchronously and the toggle shows once it is there.
        after(0.6) {
            guard let window = tab.view.window else { return }
            guard let mode else { return jump(jumps) }
            let modes = tab.diff.header.modes
            guard !modes.isHidden, let index = DiffMode.allCases.firstIndex(of: mode) else {
                FileHandle.standardError.write(Data("no diff mode toggle\n".utf8))
                return
            }
            let segment = modes.bounds.width / CGFloat(DiffMode.allCases.count)
            click(in: window, at: modes.convert(CGPoint(x: segment * (CGFloat(index) + 0.5), y: modes.bounds.midY), to: nil))
            after(0.4) {
                report("clicked \(mode.title)")
                jump(jumps)
            }
        }
    }

    /// `GITBONSAI_CLICK_FILE=<n>` clicks the n-th file in the detail panel with real mouse events and reports whether its diff opened.
    static func clickFile(on tab: RepositoryViewController) {
        driveCommitHeader(on: tab)
        guard let index = environment["GITBONSAI_CLICK_FILE"].flatMap(Int.init) else { return }
        after(0.4) {
            guard let window = tab.view.window else { return }
            let rows = fileRows(in: window)
            guard rows.indices.contains(index) else {
                FileHandle.standardError.write(Data("only \(rows.count) file rows\n".utf8))
                return
            }
            let row = rows[index]
            let point = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let hit = window.contentView?.superview?.hitTest(point).map { "\(type(of: $0))" } ?? "nothing"
            click(in: window, at: point)
            // The release is still queued; the result is there once it has been handled.
            after(0.3) {
                let opened = tab.diff.selection?.path
                FileHandle.standardError.write(Data("clicked \(row.model.selection.path) (hit \(hit)), diff shows \(opened ?? "nothing")\n".utf8))
            }
        }
    }

    /// `GITBONSAI_FILE_KEYS=down,down,up` presses arrow keys through the window after `GITBONSAI_CLICK_FILE` and reports the history row and the diff after each.
    static func pressFileKeys(on tab: RepositoryViewController) {
        guard let keys = environment["GITBONSAI_FILE_KEYS"]?.split(separator: ",").map(String.init), !keys.isEmpty else { return }
        for (step, key) in keys.enumerated() {
            after(1.2 + 0.4 * Double(step)) {
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
                after(0.2) {
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
    /// `GITBONSAI_COMMIT_COAUTHOR=Name <email>` adds a co-author, `GITBONSAI_COMMIT_SIGNOFF=1` ticks sign-off,
    /// `GITBONSAI_COMMIT_RUN=1` clicks the commit button, `GITBONSAI_COMMIT_RUN=amend-key` presses ⌥⌘⏎ and `all-key` ⇧⌘⏎ as real key events,
    /// `GITBONSAI_COMMIT_SHIFT=1` holds ⇧ through a real modifier event, so the button shows "Commit All".
    static func fillCommit(on tab: RepositoryViewController) {
        let form = tab.commitUseCase.form
        if let coAuthor = environment["GITBONSAI_COMMIT_COAUTHOR"] {
            let person = CommitTrailer(key: CommitTrailer.coAuthorKey, value: coAuthor).person
            tab.commitUseCase.addCoAuthor(name: person.name, email: person.email)
        }
        if environment["GITBONSAI_COMMIT_SIGNOFF"] == "1" { form.isSignOff = true }
        if environment["GITBONSAI_AMEND"] == "1" { form.pressAmend() }
        after(0.3) {
            if let subject = environment["GITBONSAI_COMMIT_SUBJECT"] { form.subjectText = subject }
            if let body = environment["GITBONSAI_COMMIT_BODY"] { form.bodyText = body.replacingOccurrences(of: "\\n", with: "\n") }
            form.onEdit?()
            if environment["GITBONSAI_COMMIT_RUN"] == "1" { form.pressCommit() }
            if environment["GITBONSAI_COMMIT_SHIFT"] == "1", let window = form.window, let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: KeyCode.shift) {
                // Posted to the queue, not sent, so the form's local event monitor sees it as it sees a real ⇧.
                NSApp.postEvent(event, atStart: false)
            }
            let shortcuts: [String: NSEvent.ModifierFlags] = ["amend-key": [.command, .option], "all-key": [.command, .shift]]
            if let modifiers = environment["GITBONSAI_COMMIT_RUN"].flatMap({ shortcuts[$0] }), let window = form.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: KeyCode.return) {
                // A background harness window is never key, so the key equivalent goes to the window as AppKit would route it.
                _ = window.performKeyEquivalent(with: event)
            }
        }
    }


    // MARK: Discarding

    /// `GITBONSAI_CLICK_HUNK_DISCARD=<n>` clicks "Discard Hunk" of hunk n in the open diff, `GITBONSAI_HOVER_FILE=<n>` moves the mouse onto file row n,
    /// `GITBONSAI_CLICK_FILE_DISCARD=<n>` also clicks that row's discard button; all with real mouse events through the window.
    static func discard(on tab: RepositoryViewController, attempt: Int = 0) {
        let environment = environment
        after(0.6) {
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
                let rows = fileRows(in: window)
                guard rows.indices.contains(rowIndex), let discardIndex = rows[rowIndex].model.actions.firstIndex(of: .discard) else {
                    FileHandle.standardError.write(Data("no discard button on file row \(rowIndex) of \(rows.count)\n".utf8))
                    return
                }
                let row = rows[rowIndex]
                let rect = row.actionRect(discardIndex)
                let point = row.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
                // Tracking areas follow the real cursor only, so the move goes to the list's tracking the way it would deliver it.
                trackingMove(to: point, in: window)
                if environment["GITBONSAI_CLICK_FILE_DISCARD"] != nil { click(in: window, at: point) }
            }
        }
    }

    /// The confirmation sheet for discarding. `GITBONSAI_DISCARD_ANSWER=confirm|cancel` clicks its button with real mouse events;
    /// without an answer `GITBONSAI_SHEET_SCREENSHOT=<path>` writes the sheet to a PNG while it is up.
    static func answerDiscardSheet(_ alert: NSAlert) {
        guard outputPath != nil else { return }
        let environment = environment
        after(0.5) {
            let sheet = alert.window
            FileHandle.standardError.write(Data("discard sheet: \(alert.messageText) — \(alert.plainBody)\n".utf8))
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

    // MARK: Commit header

    /// `GITBONSAI_CLICK_COMMIT_COPY=full|short` clicks the copy icon next to the commit SHA with a real click, ⌥ held for `short`, and prints the pasteboard and the icon afterwards.
    /// `GITBONSAI_CLICK_PARENT=<n>` clicks parent link n with a real click and prints the selected commit.
    static func driveCommitHeader(on tab: RepositoryViewController) {
        let environment = environment
        let copyMode = environment["GITBONSAI_CLICK_COMMIT_COPY"]
        let parent = environment["GITBONSAI_CLICK_PARENT"].flatMap(Int.init)
        selectSubject(on: tab)
        guard copyMode != nil || parent != nil else { return }
        pasteboard.clearContents()
        after(0.4) {
            guard let window = tab.view.window, let detail = views(of: DetailView.self, in: window).first else { return }
            if let copyMode, let button = detail.copyButton {
                let flags: NSEvent.ModifierFlags = copyMode == "short" ? .option : []
                printCopyFrames(button, in: detail, when: "before the click")
                click(in: window, at: button.convert(CGPoint(x: button.bounds.maxX - Theme.Space.s, y: button.bounds.midY), to: nil), flags: flags)
                after(0.2) {
                    let copied = pasteboard.string(forType: .string) ?? "nothing"
                    FileHandle.standardError.write(Data("copy (\(copyMode)) put on the pasteboard: \(copied); icon \(button.image?.accessibilityDescription ?? "none"), tooltip \(button.toolTip ?? "none")\n".utf8))
                    printCopyFrames(button, in: detail, when: "with the checkmark")
                }
                after(Theme.Detail.copiedFeedback + 0.3) { printCopyFrames(button, in: detail, when: "after the feedback") }
            }
            if let parent {
                guard detail.parentLinks.indices.contains(parent) else {
                    FileHandle.standardError.write(Data("only \(detail.parentLinks.count) parent links\n".utf8))
                    return
                }
                let link = detail.parentLinks[parent]
                let before = selectedCommit(on: tab)
                click(in: window, at: link.convert(CGPoint(x: link.bounds.midX, y: link.bounds.midY), to: nil))
                after(0.3) {
                    FileHandle.standardError.write(Data("parent link \(parent) (\(link.title)) clicked: selected \(before) -> \(selectedCommit(on: tab))\n".utf8))
                }
            }
        }
    }

    /// The copy button, its image, every view of its line and the detail panel's header, in window coordinates, after a layout pass; they must not move while the checkmark shows.
    /// `GITBONSAI_SELECT_SUBJECT=1` drags across the commit subject in the detail panel with real mouse events and prints the selection.
    static func selectSubject(on tab: RepositoryViewController) {
        guard environment["GITBONSAI_SELECT_SUBJECT"] == "1" else { return }
        after(0.4) {
            guard let window = tab.view.window, let subject = views(of: DetailView.self, in: window).first?.subjectLabel else { return }
            let start = subject.convert(CGPoint(x: subject.bounds.minX + 1, y: subject.bounds.midY), to: nil)
            let end = subject.convert(CGPoint(x: subject.bounds.maxX - 1, y: subject.bounds.midY), to: nil)
            let windowNumber = window.windowNumber
            func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // The press runs the selection's tracking loop, which takes the queued drag and release.
            for (type, point) in [(NSEvent.EventType.leftMouseDragged, end), (.leftMouseUp, end)] {
                if let queued = event(type, at: point) { NSApp.postEvent(queued, atStart: false) }
            }
            if let down = event(.leftMouseDown, at: start) { press(down, in: window) }
            after(0.3) {
                let editor = window.firstResponder as? NSTextView
                let selected = editor.map { ($0.string as NSString).substring(with: $0.selectedRange()) } ?? "nothing"
                // ⌘C would copy into the general pasteboard, which a harness run never touches; the selection is what it copies.
                FileHandle.standardError.write(Data("subject selection: \(selected), first responder \(editor.map { "\(type(of: $0))" } ?? "none")\n".utf8))
            }
        }
    }

    private static func printCopyFrames(_ button: NSButton, in detail: DetailView, when: String) {
        detail.window?.layoutIfNeeded()
        func frame(_ view: NSView) -> String {
            let rect = view.convert(view.bounds, to: nil)
            return "\(rect.minX),\(rect.minY) \(rect.width)x\(rect.height)"
        }
        let line = button.superview?.subviews.map { "\(type(of: $0)) \(frame($0))" }.joined(separator: "; ") ?? "-"
        let image = button.image.map { "\($0.size.width)x\($0.size.height) alignment \($0.alignmentRect)" } ?? "none"
        FileHandle.standardError.write(Data("copy frames \(when): button \(frame(button)), intrinsic \(button.intrinsicContentSize), image \(image), baseline \(button.firstBaselineOffsetFromTop); line [\(line)]; detail content \(detail.subviews.first.map(frame) ?? "-")\n".utf8))
    }

    private static func selectedCommit(on tab: RepositoryViewController) -> String {
        let row = tab.history.selectedRow
        guard tab.viewModel.commits.indices.contains(row) else { return "row \(row)" }
        return tab.viewModel.commits[row].id
    }

    private static func click(in window: NSWindow, at point: CGPoint, flags: NSEvent.ModifierFlags) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown) { press(down, in: window) }
    }

}
