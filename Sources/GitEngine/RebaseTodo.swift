import Foundation

/// What `git rebase --interactive` does with one line of its todo list.
public enum RebaseAction: String, Sendable, CaseIterable {
    case pick
    case reword
    case edit
    case squash
    case fixup
    case drop
    case exec

    /// The actions a commit can take; `exec` stands for a command line instead.
    public static let commitActions: [RebaseAction] = [.pick, .reword, .edit, .squash, .fixup, .drop]

    /// Squash and fixup melt a commit into the one before it.
    public var foldsIntoPrevious: Bool { self == .squash || self == .fixup }

    /// Reads a todo command in its long or abbreviated form.
    init?(todoWord word: Substring) {
        switch word {
        case "pick", "p": self = .pick
        case "reword", "r": self = .reword
        case "edit", "e": self = .edit
        case "squash", "s": self = .squash
        case "fixup", "f": self = .fixup
        case "drop", "d": self = .drop
        case "exec", "x": self = .exec
        default: return nil
        }
    }
}

/// One line of a rebase todo list as git writes it to `git-rebase-todo` and `done`.
public enum RebaseTodoLine: Sendable, Equatable {
    /// pick, reword, edit, squash, fixup or drop of a commit; the subject after the SHA is a comment git ignores.
    case commit(RebaseAction, sha: String, subject: String)
    case exec(String)
    case updateRef(String)
    /// break, label, reset, merge and anything git adds later, kept as written.
    case other(command: String, argument: String)

    /// The line git reads; `fixup -C` keeps its flag out, since the app never writes it.
    public var text: String {
        switch self {
        case let .commit(action, sha, subject): subject.isEmpty ? "\(action.rawValue) \(sha)" : "\(action.rawValue) \(sha) \(subject)"
        case let .exec(command): "exec \(command)"
        case let .updateRef(ref): "update-ref \(ref)"
        case let .other(command, argument): argument.isEmpty ? command : "\(command) \(argument)"
        }
    }

    /// Nil for comments and blank lines.
    public static func parse(_ line: Substring) -> RebaseTodoLine? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, first != "#" else { return nil }
        let command = trimmed.prefix { $0 != " " && $0 != "\t" }
        let rest = trimmed.dropFirst(command.count).drop { $0 == " " || $0 == "\t" }
        switch command {
        case "update-ref", "u":
            return .updateRef(String(rest.prefix { $0 != " " }))
        case "exec", "x":
            return .exec(String(rest))
        default:
            guard let action = RebaseAction(todoWord: command) else { return .other(command: String(command), argument: String(rest)) }
            var words = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)[...]
            // `fixup -C <sha>` and `fixup -c <sha>` take the message of the folded commit.
            if action == .fixup, let flag = words.first, flag == "-C" || flag == "-c" {
                words = rest.dropFirst(flag.count).drop { $0 == " " }.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)[...]
            }
            guard let sha = words.popFirst() else { return .other(command: String(command), argument: String(rest)) }
            // git's own lists mark the subject as a comment: `pick 1a2b3c4 # subject`.
            let subject = words.first.map { $0.hasPrefix("# ") ? $0.dropFirst(2) : $0 } ?? ""
            return .commit(action, sha: String(sha), subject: String(subject))
        }
    }

    /// The lines of a todo or done file, comments and blank lines left out.
    public static func parseList(_ text: String) -> [RebaseTodoLine] {
        text.split(whereSeparator: \.isNewline).compactMap(parse)
    }
}

/// What an interactive rebase of the current branch replays: the commits after `base`, oldest first, onto `target`.
public struct RebaseRange: Sendable, Equatable {
    public let base: String
    public let target: String
    public let commits: [RebaseCommit]
    /// Commits whose changes the target already has, by patch-id.
    public let alreadyOnTarget: Set<String>
    /// Merges between base and HEAD that the rebase leaves out, replaying only their commits.
    public let flattenedMerges: Int

    public init(base: String, target: String, commits: [RebaseCommit], alreadyOnTarget: Set<String>, flattenedMerges: Int = 0) {
        self.base = base
        self.target = target
        self.commits = commits
        self.alreadyOnTarget = alreadyOnTarget
        self.flattenedMerges = flattenedMerges
    }

    public var isInPlace: Bool { base == target }
}

/// A commit between the base and HEAD that an interactive rebase replays.
public struct RebaseCommit: Sendable, Equatable, Identifiable {
    public let id: String
    public let parents: [String]
    public let subject: String
    /// The full message as git stores it, subject included.
    public let message: String

    public init(id: String, parents: [String], subject: String, message: String) {
        self.id = id
        self.parents = parents
        self.subject = subject
        self.message = message
    }

    public var shortID: String { String(id.prefix(7)) }
}

/// One entry of the plan: a commit with its action, or a command git runs between commits.
public struct RebaseStep: Sendable, Equatable, Identifiable {
    public var action: RebaseAction
    public let commit: RebaseCommit?
    public let command: String?

    public init(_ action: RebaseAction, _ commit: RebaseCommit) {
        self.action = action
        self.commit = commit
        self.command = nil
    }

    public init(exec command: String) {
        self.action = .exec
        self.commit = nil
        self.command = command
    }

    public var id: String { commit?.id ?? "exec:\(command ?? "")" }
}

/// A commit of the history after the rebase: one replayed commit with the commits squashed or fixed up into it.
public struct RebaseResultCommit: Sendable, Equatable {
    /// The commit that keeps its place; the others melt into it.
    public let head: RebaseCommit
    public let headAction: RebaseAction
    public let folded: [RebaseStep]
    public let message: String
    /// Branches that end up here with `--update-refs`, as full ref names.
    public let branches: [String]

    public var subject: String { message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
    public var isMessageChanged: Bool { message != head.message }
    public var stopsForEdit: Bool { headAction == .edit }
}

/// Why a plan cannot run as it is.
public enum RebasePlanProblem: Sendable, Equatable {
    /// The first commit that stays squashes or fixes up, and there is nothing before it to fold into.
    case nothingToFoldInto(RebaseCommit)
    /// A reword or a squash would leave the commit without a message.
    case emptyMessage(RebaseCommit)
}

/// The todo list the app writes for `git rebase --interactive [--onto <onto>] <base>`, oldest commit first, with the messages it supplies. Lists show it newest on top through `step(atRow:)`.
public struct RebasePlan: Sendable, Equatable {
    public var base: String
    /// The commit the steps are replayed onto; nil replays them onto `base` itself, in place.
    public var onto: String?
    public var steps: [RebaseStep]
    /// Messages chosen for the resulting commits, keyed by the SHA of the commit that keeps its place. Without an entry a reword keeps the original message and a squash joins the messages.
    public var messages: [String: String]
    /// Branches other than the current one that point into the range, full ref name by commit; they move along when `updateRefs` is on.
    public var branches: [String: [String]]
    public var updateRefs: Bool
    /// Stashes uncommitted changes before the rebase and brings them back afterwards (`--autostash`).
    public var autostash: Bool

    public init(base: String, onto: String? = nil, steps: [RebaseStep], messages: [String: String] = [:], branches: [String: [String]] = [:], updateRefs: Bool = false, autostash: Bool = false) {
        self.base = base
        self.onto = onto
        self.steps = steps
        self.messages = messages
        self.branches = branches
        self.updateRefs = updateRefs
        self.autostash = autostash
    }

    /// Picks every commit in its current order.
    public init(base: String, commits: [RebaseCommit], branches: [String: [String]] = [:]) {
        self.init(base: base, steps: commits.map { RebaseStep(.pick, $0) }, branches: branches, updateRefs: !branches.isEmpty)
    }

    /// Picks every commit of the range; commits whose changes are already on the target start as drops.
    public init(range: RebaseRange, branches: [String: [String]] = [:]) {
        let steps = range.commits.map { RebaseStep(range.alreadyOnTarget.contains($0.id) ? .drop : .pick, $0) }
        self.init(base: range.base, onto: range.isInPlace ? nil : range.target, steps: steps, branches: branches, updateRefs: !branches.isEmpty)
    }

    /// Whether the steps land somewhere other than their base, so that even an unchanged list rewrites the branch.
    public var movesBase: Bool { onto != nil }

    // MARK: Listed order

    /// Lists show the steps newest on top, like the history, while `steps` keeps git's todo order: row 0 is the last step. The mapping is its own inverse.
    public func step(atRow row: Int) -> Int { steps.count - 1 - row }

    /// Moves the step shown in `row` into the gap before row `gap` of the listed order (`gap == steps.count` is below the last row), so moving up means towards newer. Returns the row it lands in.
    @discardableResult
    public mutating func moveListed(row: Int, toGap gap: Int) -> Int {
        guard steps.indices.contains(row), (0...steps.count).contains(gap) else { return row }
        let landing = gap > row ? gap - 1 : gap
        guard landing != row else { return row }
        let from = self.step(atRow: row)
        let to = self.step(atRow: landing)
        steps.insert(steps.remove(at: from), at: to)
        return landing
    }

    // MARK: Groups

    /// The steps that make one resulting commit: a commit that keeps its place and the squashes and fixups right after it. Dropped commits and commands stay out.
    /// A fold whose target was dropped melts into the previous commit that stays, as git does it.
    public var groups: [[RebaseStep]] {
        var groups: [[RebaseStep]] = []
        for step in steps where step.commit != nil && step.action != .drop {
            if step.action.foldsIntoPrevious, !groups.isEmpty {
                groups[groups.count - 1].append(step)
            } else {
                groups.append([step])
            }
        }
        return groups
    }

    /// The message the resulting commit of a group gets, before or after the user edited it.
    public func message(of group: [RebaseStep]) -> String {
        guard let head = group.first?.commit else { return "" }
        if let chosen = messages[head.id] { return chosen }
        return Self.defaultMessage(of: group)
    }

    /// What git would propose: the commit's own message, joined with the messages of the squashed commits; fixups bring none.
    public static func defaultMessage(of group: [RebaseStep]) -> String {
        let parts = group.enumerated().compactMap { offset, step -> String? in
            guard let commit = step.commit, offset == 0 || step.action == .squash else { return nil }
            return commit.message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Whether the user can choose the message of a group: a reword, or a squash that has to join messages.
    public static func hasEditableMessage(_ group: [RebaseStep]) -> Bool {
        group.first?.action == .reword || group.contains { $0.action == .squash }
    }

    /// The history after the rebase, oldest first, without the base.
    public var result: [RebaseResultCommit] {
        groups.compactMap { group in
            guard let head = group.first, let commit = head.commit else { return nil }
            let refs = updateRefs ? group.flatMap { branches[$0.id] ?? [] } : []
            return RebaseResultCommit(head: commit, headAction: head.action, folded: Array(group.dropFirst()), message: message(of: group), branches: refs)
        }
    }

    public var problem: RebasePlanProblem? {
        if let first = steps.first(where: { $0.commit != nil && $0.action != .drop }), first.action.foldsIntoPrevious, let commit = first.commit {
            return .nothingToFoldInto(commit)
        }
        for group in groups where Self.hasEditableMessage(group) {
            if message(of: group).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let commit = group.first?.commit { return .emptyMessage(commit) }
        }
        return nil
    }

    /// True when the rebase would rewrite nothing: `commits` picked in their order, every message as it was.
    public func isUnchanged(from commits: [RebaseCommit]) -> Bool {
        steps.allSatisfy { $0.action == .pick } && steps.compactMap(\.commit?.id) == commits.map(\.id) && result.allSatisfy { !$0.isMessageChanged }
    }

    public var dropsEverything: Bool { steps.allSatisfy { $0.commit == nil || $0.action == .drop } }

    // MARK: Todo

    /// The todo list git runs. With `updateRefs` each stacked branch follows its commit: its `update-ref` line comes after the squashes and fixups that melt into that commit.
    public var todoLines: [RebaseTodoLine] {
        var lines: [RebaseTodoLine] = []
        var pendingRefs: [String] = []
        for (index, step) in steps.enumerated() {
            if let commit = step.commit {
                lines.append(.commit(step.action, sha: commit.id, subject: Self.oneLine(commit.subject)))
                if updateRefs { pendingRefs += branches[commit.id] ?? [] }
            } else if let command = step.command {
                lines.append(.exec(command))
            }
            let next = steps.dropFirst(index + 1).first
            let chainContinues = next.map { $0.commit != nil && $0.action.foldsIntoPrevious } ?? false
            if !chainContinues {
                lines += pendingRefs.map(RebaseTodoLine.updateRef)
                pendingRefs = []
            }
        }
        return lines
    }

    public var todoText: String { todoLines.map(\.text).joined(separator: "\n") + "\n" }

    /// The messages git asks for while it runs, keyed by the SHA of the todo line it has just done.
    /// A reword asks right after its commit; a squash chain asks once, at its last line, so every folding line of a chain gets the joined message.
    public var editorMessages: [String: String] {
        var result: [String: String] = [:]
        for group in groups {
            guard let head = group.first, let commit = head.commit else { continue }
            let message = message(of: group)
            if head.action == .reword { result[commit.id] = message }
            if group.contains(where: { $0.action == .squash }) {
                for step in group.dropFirst() { if let id = step.commit?.id { result[id] = message } }
            }
        }
        return result
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
