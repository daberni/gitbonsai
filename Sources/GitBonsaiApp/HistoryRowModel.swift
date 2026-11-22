import AppKit
import GitEngine

/// Turns one row of the view model into what a history row draws.
@MainActor
enum HistoryRowModel {
    static func make(row index: Int, in viewModel: GraphViewModel, isSelected: Bool, columns: HistoryColumns, search: HistorySearchController) -> GraphRowView.Model {
        let commit = viewModel.commits[index]
        let kind = viewModel.kinds[index]
        let refs = viewModel.refsByCommit[commit.id] ?? []
        let isDetachedHead = kind != .wip && viewModel.currentBranch == nil && commit.id == viewModel.headSHA
        let stash = viewModel.stashesByCommit[commit.id]
        var wipCounts: (changed: Int, staged: Int, untracked: Int)?
        if kind == .wip, let status = viewModel.status {
            let untracked = status.entries.filter(\.isUntracked).count
            wipCounts = (status.unstaged.count - untracked + status.conflicted.count, status.staged.count, untracked)
        }
        let subject = stash.map { "\($0.selector): \($0.message)" } ?? commit.subject
        let isMatch = search.isMatch(row: index)
        return GraphRowView.Model(
            commit: commit,
            row: viewModel.rows[index],
            previous: index > 0 ? viewModel.rows[index - 1] : nil,
            next: index + 1 < viewModel.rows.count ? viewModel.rows[index + 1] : nil,
            kind: kind,
            previousKind: index > 0 ? viewModel.kinds[index - 1] : nil,
            wipLaneAbove: viewModel.wipStrand.flatMap { index >= 1 && index <= $0.headRow ? $0.lane : nil },
            wipLaneBelow: viewModel.wipStrand.flatMap { index < $0.headRow ? $0.lane : nil },
            pills: pills(for: refs, branchesElsewhere: viewModel.branchesInOtherWorktrees, detachedHead: isDetachedHead),
            isHead: isDetachedHead || refs.contains(where: \.isHead),
            dimmed: kind != .stash && !viewModel.isReachableFromHead(commit.id),
            isSelected: isSelected,
            subject: subject,
            wipCounts: wipCounts,
            isSearchMiss: !isMatch,
            avatar: kind == .commit ? AvatarStore.shared.image(email: commit.authorEmail, commit: commit.id, in: viewModel.repository) : nil,
            highlights: isMatch ? highlights(of: search.search, subject: subject, commit: commit) : GraphRowView.Highlights(),
            columns: columns
        )
    }

    /// What a match shows of the query: its occurrences in the subject and author, and the SHA prefix it names.
    private static func highlights(of search: CommitSearch?, subject: String, commit: Commit) -> GraphRowView.Highlights {
        guard let search else { return GraphRowView.Highlights() }
        let shaLength = search.matchesSHA(commit.id) ? min(search.text.utf16.count, GraphRowView.shortSHALength) : 0
        return GraphRowView.Highlights(subject: search.occurrences(in: subject), author: search.occurrences(in: commit.authorName), shaPrefix: shaLength)
    }

    /// A local branch and its same-named remote branches share one label. The first glyph says where the branch stands: checked out here, checked out in another worktree, or just local.
    /// A detached HEAD has no branch to carry that mark, so the commit gets a "HEAD" label of its own in front of its other labels.
    static func pills(for refs: [Ref], branchesElsewhere elsewhere: [String: Worktree], detachedHead: Bool) -> [PillModel] {
        var order: [String] = []
        var local: [String: Ref] = [:]
        var remoteCount: [String: Int] = [:]
        var others: [PillModel] = []
        for ref in refs {
            switch ref.kind {
            case .localBranch:
                if local[ref.name] == nil, remoteCount[ref.name] == nil { order.append(ref.name) }
                local[ref.name] = ref
            case .remoteBranch(let remote):
                let base = String(ref.name.dropFirst(remote.count + 1))
                // `origin/HEAD` only points at the remote's default branch and carries no information of its own.
                if base == "HEAD" { continue }
                if local[base] == nil, remoteCount[base] == nil { order.append(base) }
                remoteCount[base, default: 0] += 1
            case .tag:
                others.append(PillModel(name: ref.name, glyphs: [.tag], isHead: false, ref: .tag(ref.name)))
            case .stash:
                continue
            case .other:
                others.append(PillModel(name: ref.name, glyphs: [], isHead: false, ref: .other(ref.name)))
            }
        }
        let branches = order.map { name -> PillModel in
            var glyphs: [Glyph] = []
            if let ref = local[name] {
                if ref.isHead { glyphs += [.check, .laptop] }
                else if elsewhere[ref.fullName] != nil { glyphs.append(.bonsaiLinked) }
                else { glyphs.append(.laptop) }
            }
            glyphs += Array(repeating: Glyph.cloud, count: remoteCount[name] ?? 0)
            return PillModel(name: name, glyphs: glyphs, isHead: local[name]?.isHead ?? false, ref: .branch(name))
        }
        // The pill list is drawn right to left, so the most important label comes first.
        let head = detachedHead ? [PillModel(name: "HEAD", glyphs: [.check, .laptop], isHead: true, ref: .detachedHead)] : []
        return head + branches.sorted { $0.isHead && !$1.isHead } + others
    }
}
