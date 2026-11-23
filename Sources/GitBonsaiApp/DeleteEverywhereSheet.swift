import AppKit
import GitEngine

/// Asks before "Delete everywhere": every ref it would delete as a row with a checkbox, its pill, its commit and whether its commits exist nowhere else, then the git commands of the checked rows.
@MainActor
final class DeleteEverywhereSheet: NSObject {
    private typealias M = Theme.Confirmation
    private let deletion: BranchDeletion
    private let alert = NSAlert()
    private var boxes: [NSButton] = []
    private let commands = NSTextField(wrappingLabelWithString: "")

    private init(_ deletion: BranchDeletion) {
        self.deletion = deletion
        super.init()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "branch.deleteBranches.title", defaultValue: "Delete Branches", bundle: .module)
        alert.addButton(withTitle: String(localized: "common.delete", defaultValue: "Delete", bundle: .module))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        alert.buttons.first?.hasDestructiveAction = true
        alert.setBody(body(), plain: plain)
    }

    /// The checked refs, or nil when cancelled.
    static func ask(_ deletion: BranchDeletion, prompter: ActionPrompter) async -> [BranchDeletion.Target]? {
        let sheet = DeleteEverywhereSheet(deletion)
        guard await prompter.confirm(sheet.alert) else { return nil }
        return sheet.checked
    }

    private var checked: [BranchDeletion.Target] {
        zip(deletion.targets, boxes).filter { $0.1.state == .on }.map(\.0)
    }

    private var plain: RefString {
        let rows = deletion.targets.map { target in "\(target.name) \(target.commit.prefix(RefString.shortSHA))\(target.isUnmerged ? " " + unmergedText : "")" }
        return RefString(verbatim: (rows + checked.map(\.commandLine)).joined(separator: "\n"))
    }

    private var unmergedText: String { String(localized: "branch.deleteBranches.unmerged", defaultValue: "unmerged", bundle: .module, comment: "Badge of a ref whose commits are on no other branch.") }

    private func body() -> NSView {
        let width = M.wideWidth
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = M.rowSpacing
        for target in deletion.targets {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled))
            box.state = .on
            box.setAccessibilityLabel(target.name)
            boxes.append(box)
            let pill = RefPillView(target.name, kind: target.isRemote ? .remoteBranch : .branch, font: Theme.caption)
            let sha = NSTextField(labelWithString: String(target.commit.prefix(RefString.shortSHA)))
            sha.font = Theme.monoSmall
            sha.textColor = Theme.inkMuted
            sha.toolTip = target.commit
            var views: [NSView] = [box, pill, sha]
            if target.isUnmerged {
                let badge = NSTextField(labelWithString: unmergedText)
                badge.font = Theme.caption
                badge.textColor = Theme.persimmon
                badge.toolTip = String(localized: "branch.deleteBranches.unmergedToolTip", defaultValue: "Has commits that no other branch or tag contains", bundle: .module)
                views.append(badge)
            }
            let fixed = box.fittingSize.width + sha.fittingSize.width + (target.isUnmerged ? views[3].fittingSize.width : 0) + CGFloat(views.count - 1) * M.rowSpacing
            let size = pill.fit(width: width - fixed)
            pill.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([pill.widthAnchor.constraint(equalToConstant: size.width), pill.heightAnchor.constraint(equalToConstant: size.height)])
            let row = NSStackView(views: views)
            row.spacing = M.rowSpacing
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }
        stack.setCustomSpacing(M.spacing, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        commands.font = Theme.monoSmall
        commands.textColor = Theme.inkMuted
        commands.preferredMaxLayoutWidth = width
        commands.isSelectable = true
        stack.addArrangedSubview(commands)
        showCommands()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.frame.size = stack.fittingSize
        stack.translatesAutoresizingMaskIntoConstraints = true
        return stack
    }

    private func showCommands() {
        commands.stringValue = checked.map(\.commandLine).joined(separator: "\n")
        alert.buttons.first?.isEnabled = !checked.isEmpty
    }

    @objc private func toggled() {
        showCommands()
        alert.setBody(alert.accessoryView ?? NSView(), plain: plain)
    }
}
