import Foundation
import GitEngine

/// The rows of the Tags list with their marks, as the branch labels draw them: laptop for a tag only here, cloud for one on the remote,
/// a clay cloud and wash for one that differs, a muted row for one only on the remote. With several remotes each mark names its remote.
struct TagRows {
    let rows: [PanelRow]
    let scopes: [PanelScope]
    private let statesByName: [String: [(remote: String, state: TagSyncState)]]

    init(tags: [Tag], remotes: [String], states: [(remote: String, states: [String: TagSyncState])] = []) {
        var byName: [String: [(remote: String, state: TagSyncState)]] = [:]
        for (remote, remoteStates) in states {
            for (name, state) in remoteStates { byName[name, default: []].append((remote, state)) }
        }
        statesByName = byName
        let labelled = remotes.count > 1
        let localNames = Set(tags.map(\.name))

        let localRows = tags.map { tag in Self.row(tag, states: byName[tag.name] ?? [], labelled: labelled) }
        let remoteOnly = byName.filter { name, states in !localNames.contains(name) && states.contains { if case .remoteOnly = $0.state { true } else { false } } }
        let remoteRows = remoteOnly.keys.sorted().map { name in Self.remoteOnlyRow(name, states: byName[name] ?? [], labelled: labelled) }
        rows = localRows + remoteRows

        // The scopes are offered from the start whenever there is a remote, empty until it answers, so the switch in the title line never appears late.
        guard !remotes.isEmpty else {
            scopes = []
            return
        }
        let onlyLocal = Set(localNames.filter { name in byName[name]?.allSatisfy { $0.state == .localOnly } ?? false })
        let differing = Set(byName.filter { _, states in states.contains { if case .differs = $0.state { true } else { false } } }.keys)
        let onlyRemote = Set(remoteOnly.keys)
        scopes = [
            PanelScope(title: String(localized: "tag.scope.localOnly", defaultValue: "Local only", bundle: .module, comment: "Tag filter: tags no remote has."), empty: String(localized: "tag.scope.localOnlyEmpty", defaultValue: "No local-only tags", bundle: .module)) { onlyLocal.contains($0) },
            PanelScope(title: String(localized: "tag.scope.remoteOnly", defaultValue: "Remote only", bundle: .module, comment: "Tag filter: tags only a remote has."), empty: String(localized: "tag.scope.remoteOnlyEmpty", defaultValue: "No remote-only tags", bundle: .module)) { onlyRemote.contains($0) },
            PanelScope(title: String(localized: "tag.scope.diverging", defaultValue: "Diverging", bundle: .module, comment: "Tag filter: tags that point elsewhere on a remote."), empty: String(localized: "tag.scope.divergingEmpty", defaultValue: "No diverging tags", bundle: .module)) { differing.contains($0) },
        ]
    }

    /// The remotes that have the tag while this repository does not, which "Fetch Tag" offers.
    func remotesOnlyHaving(_ name: String) -> [String] {
        (statesByName[name] ?? []).compactMap { if case .remoteOnly = $0.state { $0.remote } else { nil } }
    }

    /// "Push Tag" goes straight to the remotes that lack the tag; when none is known to lack it, every remote is offered.
    func remotesPreferredForPush(_ name: String, all remotes: [String]) -> [String] {
        let lacking = (statesByName[name] ?? []).filter { $0.state == .localOnly }.map(\.remote)
        return lacking.isEmpty ? remotes : lacking
    }

    /// How a local tag can be pushed to one remote: added where the remote lacks it, replaced (a force push) where the remote's differs.
    enum PushOffer: Equatable {
        case add, replace
    }

    /// What a local tag's menu offers for each remote: a push where the remote lacks the tag or has another one, a delete where it has one. A remote that has not answered yet gets both.
    func remoteOffers(_ name: String, remotes: [String]) -> [(remote: String, push: PushOffer?, canDelete: Bool)] {
        let states = statesByName[name] ?? []
        return remotes.map { remote in
            switch states.first(where: { $0.remote == remote })?.state {
            case nil: (remote, .add, true)
            case .same: (remote, nil, true)
            case .localOnly: (remote, .add, false)
            case .differs: (remote, .replace, true)
            case .remoteOnly: (remote, nil, true)
            }
        }
    }

    // MARK: Rows

    private static func row(_ tag: Tag, states: [(remote: String, state: TagSyncState)], labelled: Bool) -> PanelRow {
        let notes = (tag.isAnnotated ? [String(localized: "tag.row.annotated", defaultValue: "Annotated tag", bundle: .module)] : []) + states.map { describe($0.state, of: tag.name, on: $0.remote) }
        let differs = states.contains { if case .differs = $0.state { true } else { false } }
        var row = PanelRow(id: tag.name, glyph: .tag, title: tag.name, marker: tag.isAnnotated ? "◆" : nil, tooltip: notes.isEmpty ? nil : notes.joined(separator: "\n"), detail: tag.subject, date: tag.date, sha: String(tag.commitID.prefix(RefString.shortSHA)), searchText: tag.subject)
        row.badges = states.map { badge(for: $0.state, remote: $0.remote, labelled: labelled) }
        row.isHighlighted = differs
        return row
    }

    private static func remoteOnlyRow(_ name: String, states: [(remote: String, state: TagSyncState)], labelled: Bool) -> PanelRow {
        let having = states.compactMap { entry -> (remote: String, target: TagTarget)? in if case .remoteOnly(let target) = entry.state { (entry.remote, target) } else { nil } }
        let target = having.first?.target
        let isAnnotated = target.map { $0.objectID != $0.commitID } ?? false
        let remotes = having.map(\.remote).joined(separator: ", ")
        let detail = String(localized: "tag.status.onlyRemote", defaultValue: "Only on \(remotes), not fetched yet", bundle: .module, comment: "A tag only on the listed remotes.")
        var row = PanelRow(id: name, glyph: .tag, title: name, marker: isAnnotated ? "◆" : nil, tooltip: states.map { describe($0.state, of: name, on: $0.remote) }.joined(separator: "\n"), detail: detail, date: nil, sha: String((target?.commitID ?? "").prefix(RefString.shortSHA)), searchText: detail)
        row.badges = states.map { badge(for: $0.state, remote: $0.remote, labelled: labelled) }
        row.isDimmed = true
        return row
    }

    private static func badge(for state: TagSyncState, remote: String, labelled: Bool) -> PanelBadge {
        let label = labelled ? remote : nil
        return switch state {
        case .same, .remoteOnly: PanelBadge(glyph: .cloud, label: label, tone: .muted)
        case .localOnly: PanelBadge(glyph: .laptop, label: label, tone: .muted)
        case .differs: PanelBadge(glyph: .cloud, label: label, tone: .alert)
        }
    }

    private static func describe(_ state: TagSyncState, of name: String, on remote: String) -> String {
        switch state {
        case .same:
            return String(localized: "tag.status.on", defaultValue: "On \(remote)", bundle: .module, comment: "Tooltip of a tag the remote has too.")
        case .localOnly:
            return String(localized: "tag.status.onlyLocal", defaultValue: "Only local, not on \(remote)", bundle: .module)
        case .remoteOnly(let target):
            let commit = String(target.commitID.prefix(RefString.shortSHA))
            return String(localized: "tag.status.onlyRemoteCommit", defaultValue: "Only on \(remote) (\(commit)), not fetched yet", bundle: .module)
        case .differs(let local, let other):
            let here = String(local.commitID.prefix(RefString.shortSHA))
            guard local.commitID == other.commitID else {
                let there = String(other.commitID.prefix(RefString.shortSHA))
                return String(localized: "tag.status.differentCommits", defaultValue: "Differs from \(remote): \(here) here, \(there) there", bundle: .module)
            }
            // Same commit, so the tags differ in kind, or both are annotated with different tag objects.
            switch (isAnnotated(local), isAnnotated(other)) {
            case (false, true):
                return String(localized: "tag.status.lightweightHere", defaultValue: "Differs from \(remote): same commit \(here), but a lightweight tag here and an annotated tag there", bundle: .module)
            case (true, false):
                return String(localized: "tag.status.annotatedHere", defaultValue: "Differs from \(remote): same commit \(here), but an annotated tag here and a lightweight tag there", bundle: .module)
            default:
                return String(localized: "tag.status.differentAnnotated", defaultValue: "Differs from \(remote): same commit \(here), but different annotated tags here and there", bundle: .module)
            }
        }
    }

    private static func isAnnotated(_ target: TagTarget) -> Bool {
        target.objectID != target.commitID
    }
}
