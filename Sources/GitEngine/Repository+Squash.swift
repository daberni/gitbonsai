import Foundation

extension Repository {
    /// The plan that squashes `commits`, consecutive commits on HEAD's first-parent line, into the oldest of them: it is picked, the others squash into it in their order, everything above is picked again.
    /// git keeps the author of the oldest commit; the message starts as `squashMessage(_:)` and the caller may replace it in `messages`. Stacked branches move along.
    public func squashPlan(_ commits: [String]) async throws -> RebasePlan {
        guard Set(commits).count >= 2 else { throw RebasePlanError.tooFewCommits }
        var oldest: (id: String, distance: Int)?
        for id in commits {
            guard await isAncestorOfHead(id) else { throw RebasePlanError.notOnCurrentBranch }
            let count = try await runner.run(["rev-list", "--count", "--first-parent", "\(id)..HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let distance = Int(count) ?? 0
            if distance > oldest?.distance ?? -1 { oldest = (id, distance) }
        }
        guard let oldest else { throw RebasePlanError.tooFewCommits }
        guard let base = await resolveCommit("\(oldest.id)^") else { throw RebasePlanError.rootCommit }
        let range: RebaseRange
        do {
            range = try await rebaseRange(from: base, onto: base)
        } catch RebasePlanError.mergeInRange {
            throw RebasePlanError.containsMerge
        }
        // A merge anywhere between the base and HEAD would be flattened by the replay; squashing never rewrites more than the line it shows.
        guard range.flattenedMerges == 0 else { throw RebasePlanError.containsMerge }
        let selected = Set(commits)
        let positions = range.commits.indices.filter { selected.contains(range.commits[$0].id) }
        guard positions.count == selected.count else { throw RebasePlanError.notOnCurrentBranch }
        guard positions == Array(0..<selected.count) else { throw RebasePlanError.notConsecutive }
        var plan = RebasePlan(base: base, commits: range.commits, branches: await stackedBranches(in: range.commits))
        for index in positions.dropFirst() { plan.steps[index].action = .squash }
        plan.messages[range.commits[0].id] = Self.squashMessage(Array(range.commits.prefix(selected.count)))
        return plan
    }

    /// The messages of `commits`, oldest first, joined with a blank line as `git rebase -i` joins a squash; the trailers of all of them (`Co-Authored-By: …`) follow once at the end, each kept the first time it appears.
    public static func squashMessage(_ commits: [RebaseCommit]) -> String {
        var bodies: [String] = []
        var trailers: [String] = []
        for commit in commits {
            let (body, own) = splitTrailers(commit.message)
            if !body.isEmpty { bodies.append(body) }
            for trailer in own where !trailers.contains(trailer) { trailers.append(trailer) }
        }
        let text = bodies.joined(separator: "\n\n")
        guard !trailers.isEmpty else { return text }
        return text + "\n\n" + trailers.joined(separator: "\n")
    }

    /// A message's last paragraph is its trailer block when it is not the subject and every line reads `Token: value`.
    static func splitTrailers(_ message: String) -> (body: String, trailers: [String]) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gap = trimmed.range(of: "\n\n", options: .backwards) else { return (trimmed, []) }
        let lines = trimmed[gap.upperBound...].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty, lines.allSatisfy(isTrailer) else { return (trimmed, []) }
        return (trimmed[..<gap.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), lines)
    }

    private static func isTrailer(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, line[line.index(after: colon)...].hasPrefix(" ") else { return false }
        return line[..<colon].allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
