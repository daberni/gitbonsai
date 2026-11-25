import XCTest
@testable import GitEngine

final class ConflictTests: XCTestCase {
    /// Commits `base` on main, `feature` on a branch from there and `main` on main, then merges the branch, which must stop.
    /// Each closure changes the working tree; its changes are committed with `git add -A`.
    private func merge(base: (FixtureRepo) throws -> Void, feature: (FixtureRepo) throws -> Void, main: (FixtureRepo) throws -> Void) throws -> FixtureRepo {
        let fixture = try FixtureRepo()
        try base(fixture)
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "base")
        try fixture.git("switch", "-q", "-c", "feature")
        try feature(fixture)
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "feature")
        try fixture.git("switch", "-q", "main")
        try main(fixture)
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "main")
        XCTAssertThrowsError(try fixture.git("merge", "feature"), "the merge stops on a conflict")
        return fixture
    }

    private func writeData(_ fixture: FixtureRepo, _ file: String, _ data: Data) throws {
        try data.write(to: fixture.url.appendingPathComponent(file))
    }

    private func readData(_ fixture: FixtureRepo, _ file: String) throws -> Data {
        try Data(contentsOf: fixture.url.appendingPathComponent(file))
    }

    private func exists(_ fixture: FixtureRepo, _ file: String) -> Bool {
        FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent(file).path)
    }

    private func unmerged(_ fixture: FixtureRepo) throws -> String {
        try fixture.git("diff", "--name-only", "--diff-filter=U")
    }

    // MARK: Text

    private func document(_ conflict: Conflict) throws -> MergeDocument {
        guard case .text(let document) = conflict.content else { throw XCTSkip("text conflict expected, got \(conflict.content)") }
        return document
    }

    func testChangesOfOneSideAreTakenAndOverlappingChangesConflict() async throws {
        let fixture = try merge(
            base: { try $0.write("f.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\n") },
            feature: { try $0.write("f.txt", "one\nTWO feature\nthree\nfour\nfive\nsix\nSEVEN feature\n") },
            main: { try $0.write("f.txt", "ONE main\nTWO main\nthree\nfour\nFIVE main\nsix\nSEVEN feature\n") })
        defer { fixture.remove() }

        let conflict = try await fixture.repository.conflict(at: "f.txt")
        let document = try document(conflict)
        XCTAssertEqual(document.regions, [
            .change(MergeChange(base: ["one", "two"], ours: ["ONE main", "TWO main"], theirs: ["one", "TWO feature"], kind: .conflict)),
            .same(["three", "four"]),
            .change(MergeChange(base: ["five"], ours: ["FIVE main"], theirs: ["five"], kind: .ours)),
            .same(["six"]),
            .change(MergeChange(base: ["seven"], ours: ["SEVEN feature"], theirs: ["SEVEN feature"], kind: .both)),
        ], "touching changes of both sides form one conflict, as in git's merge")
        let automatic = document.changes.map(\.automatic)
        XCTAssertNil(document.text(with: automatic), "an open conflict leaves no result")
        XCTAssertEqual(document.text(with: [["ONE main", "TWO feature"]] + automatic.dropFirst()), "ONE main\nTWO feature\nthree\nfour\nFIVE main\nsix\nSEVEN feature\n")
    }

    func testInsertionsAtTheSamePlaceConflictAndElsewhereAreTaken() async throws {
        let fixture = try merge(
            base: { try $0.write("f.txt", "a\nb\nc\n") },
            feature: { try $0.write("f.txt", "a\nfeature\nb\nc\nend\n") },
            main: { try $0.write("f.txt", "a\nmain\nb\nc\n") })
        defer { fixture.remove() }

        let conflict = try await fixture.repository.conflict(at: "f.txt")
        let document = try document(conflict)
        XCTAssertEqual(document.regions, [
            .same(["a"]),
            .change(MergeChange(base: [], ours: ["main"], theirs: ["feature"], kind: .conflict)),
            .same(["b", "c"]),
            .change(MergeChange(base: [], ours: [], theirs: ["end"], kind: .theirs)),
        ])
    }

    func testWordMergeCombinesDifferentWordsOfOneLine() async throws {
        let fixture = try merge(
            base: { try $0.write("f.txt", "let greeting = hello(name)\n") },
            feature: { try $0.write("f.txt", "let greeting = hello(fullName)\n") },
            main: { try $0.write("f.txt", "var greeting = hello(name)\n") })
        defer { fixture.remove() }
        let repo = fixture.repository

        let conflict = try await repo.conflict(at: "f.txt")
        let change = try XCTUnwrap(try document(conflict).changes.first)
        XCTAssertEqual(change.kind, .conflict)
        let merged = try await repo.mergeWords(of: change)
        XCTAssertEqual(merged, ["var greeting = hello(fullName)"])
    }

    func testWordMergeLeavesTheSameWordChangedTwiceAConflict() async throws {
        let fixture = try merge(
            base: { try $0.write("f.txt", "let greeting = hello(name)\n") },
            feature: { try $0.write("f.txt", "let greeting = hi(name)\n") },
            main: { try $0.write("f.txt", "let greeting = hey(name)\n") })
        defer { fixture.remove() }
        let repo = fixture.repository

        let conflict = try await repo.conflict(at: "f.txt")
        let change = try XCTUnwrap(try document(conflict).changes.first)
        let merged = try await repo.mergeWords(of: change)
        XCTAssertNil(merged)
    }

    func testResolvingWithTextStagesItAndLeavesNoConflict() async throws {
        let fixture = try merge(
            base: { try $0.write("f.txt", "a\nb\nc\n") },
            feature: { try $0.write("f.txt", "a\nB feature\nc\n") },
            main: { try $0.write("f.txt", "a\nB main\nc\n") })
        defer { fixture.remove() }
        let repo = fixture.repository

        try await repo.resolveConflict("f.txt", with: "a\nB both\nc\n", encoding: .utf8)
        XCTAssertEqual(try unmerged(fixture), "")
        XCTAssertEqual(try fixture.git("show", ":f.txt"), "a\nB both\nc")
        let stages = try await repo.conflictStages()
        XCTAssertTrue(stages.isEmpty)
    }

    func testBothAddedHasAnEmptyBase() async throws {
        let fixture = try merge(
            base: { try $0.write("other.txt", "x\n") },
            feature: { try $0.write("new.txt", "feature\n") },
            main: { try $0.write("new.txt", "main\n") })
        defer { fixture.remove() }

        let conflict = try await fixture.repository.conflict(at: "new.txt")
        XCTAssertEqual(conflict.kind, .bothAdded)
        XCTAssertEqual(try document(conflict).regions, [.change(MergeChange(base: [], ours: ["main"], theirs: ["feature"], kind: .conflict))])
    }

    func testLatin1ConflictKeepsItsBytesWhenResolved() async throws {
        let fixture = try merge(
            base: { try self.writeData($0, "l.txt", Data("caf\u{E9}\nx\n".utf8).latin1) },
            feature: { try self.writeData($0, "l.txt", Data("caf\u{E9} feature\nx\n".utf8).latin1) },
            main: { try self.writeData($0, "l.txt", Data("caf\u{E9} main\nx\n".utf8).latin1) })
        defer { fixture.remove() }
        let repo = fixture.repository

        let conflict = try await repo.conflict(at: "l.txt")
        let text = try document(conflict)
        XCTAssertEqual(text.encoding, .latin1)
        XCTAssertEqual(text.changes.first?.ours, ["caf\u{E9} main"])
        let result = try XCTUnwrap(text.text(with: [text.changes[0].theirs]))
        try await repo.resolveConflict("l.txt", with: result, encoding: text.encoding)
        XCTAssertEqual(try readData(fixture, "l.txt"), Data("caf\u{E9} feature\nx\n".utf8).latin1, "the é goes back as the one byte E9")
    }

    func testCarriageReturnsStayOnTheirLines() async throws {
        let fixture = try merge(
            base: { try $0.git("config", "core.autocrlf", "false"); try $0.write("w.txt", "a\r\nb\r\n") },
            feature: { try $0.write("w.txt", "a\r\nb feature\r\n") },
            main: { try $0.write("w.txt", "a\r\nb main\r\n") })
        defer { fixture.remove() }

        let conflict = try await fixture.repository.conflict(at: "w.txt")
        let text = try document(conflict)
        XCTAssertEqual(text.regions, [.same(["a\r"]), .change(MergeChange(base: ["b\r"], ours: ["b main\r"], theirs: ["b feature\r"], kind: .conflict))])
        XCTAssertEqual(text.text(with: [text.changes[0].ours]), "a\r\nb main\r\n")
    }

    // MARK: Delete and modify

    func testDeletedByThemOffersTheRemainingTextAndCanBeKeptOrDeleted() async throws {
        func makeFixture() throws -> FixtureRepo {
            try merge(
                base: { try $0.write("d.txt", "keep\n") },
                feature: { try FileManager.default.removeItem(at: $0.url.appendingPathComponent("d.txt")) },
                main: { try $0.write("d.txt", "changed\n") })
        }
        let kept = try makeFixture()
        defer { kept.remove() }
        let conflict = try await kept.repository.conflict(at: "d.txt")
        XCTAssertEqual(conflict.kind, .deletedByThem)
        XCTAssertEqual(conflict.content, .oneSided(remaining: "changed\n"))
        try await kept.repository.resolveConflicts(["d.txt"], taking: .ours)
        XCTAssertEqual(try unmerged(kept), "")
        XCTAssertEqual(try kept.git("show", ":d.txt"), "changed")

        let deleted = try makeFixture()
        defer { deleted.remove() }
        try await deleted.repository.resolveConflictsByDeleting(["d.txt"])
        XCTAssertEqual(try unmerged(deleted), "")
        XCTAssertFalse(exists(deleted, "d.txt"))
        XCTAssertEqual(try deleted.git("ls-files", "--", "d.txt"), "")
    }

    func testDeletedByUsKeepsTheirSide() async throws {
        let fixture = try merge(
            base: { try $0.write("d.txt", "keep\n") },
            feature: { try $0.write("d.txt", "changed in feature\n") },
            main: { try FileManager.default.removeItem(at: $0.url.appendingPathComponent("d.txt")) })
        defer { fixture.remove() }

        let conflict = try await fixture.repository.conflict(at: "d.txt")
        XCTAssertEqual(conflict.kind, .deletedByUs)
        try await fixture.repository.resolveConflicts(["d.txt"], taking: .theirs)
        XCTAssertEqual(try unmerged(fixture), "")
        XCTAssertEqual(try String(decoding: readData(fixture, "d.txt"), as: UTF8.self), "changed in feature\n")
    }

    // MARK: Several files at once

    /// "Accept <branch>" over a selection: a file that side changed takes its version, a file that side deleted goes; "Keep" takes whichever side still has the file.
    func testAcceptingOneSideForSeveralFilesTakesOrDeletesEach() async throws {
        let setup: (FixtureRepo) throws -> Void = { try $0.write("both.txt", "base\n"); try $0.write("gone.txt", "keep\n"); try $0.write("kept.txt", "keep\n") }
        let fixture = try merge(
            base: setup,
            feature: { try $0.write("both.txt", "feature\n"); try $0.write("gone.txt", "changed in feature\n"); try FileManager.default.removeItem(at: $0.url.appendingPathComponent("kept.txt")) },
            main: { try $0.write("both.txt", "main\n"); try FileManager.default.removeItem(at: $0.url.appendingPathComponent("gone.txt")); try $0.write("kept.txt", "changed in main\n") })
        defer { fixture.remove() }
        let repo = fixture.repository

        try await repo.resolveConflicts(["both.txt", "gone.txt"], taking: .ours)
        try await repo.keepConflictedFiles(["kept.txt"])

        XCTAssertEqual(try unmerged(fixture), "")
        XCTAssertEqual(try fixture.git("show", ":both.txt"), "main")
        XCTAssertFalse(exists(fixture, "gone.txt"), "main deleted it")
        XCTAssertEqual(try fixture.git("show", ":kept.txt"), "changed in main")
    }

    /// Marking resolved stages the edited file; restoring the markers makes it unmerged again with both sides in the file, as long as the merge runs.
    func testMarkingResolvedAndRestoringTheMarkers() async throws {
        let fixture = try merge(
            base: { try $0.write("f.txt", "base\n") },
            feature: { try $0.write("f.txt", "feature\n") },
            main: { try $0.write("f.txt", "main\n") })
        defer { fixture.remove() }
        let repo = fixture.repository
        try fixture.write("f.txt", "edited by hand\n")

        try await repo.markConflictsResolved(["f.txt"])
        XCTAssertEqual(try unmerged(fixture), "")
        XCTAssertEqual(try fixture.git("show", ":f.txt"), "edited by hand")

        try await repo.restoreConflictMarkers(["f.txt"])
        let stages = try await repo.conflictStages()
        XCTAssertEqual(stages["f.txt"]?.kind, .bothModified)
        let text = try String(decoding: readData(fixture, "f.txt"), as: UTF8.self)
        XCTAssertTrue(text.contains("main") && text.contains("feature") && text.contains("======="), text)
    }

    func testCommitsTouchingTheConflictComeFromBothSides() async throws {
        let fixture = try merge(
            base: { try $0.write("f.txt", "base\n") },
            feature: { try $0.write("f.txt", "feature\n") },
            main: { try $0.write("f.txt", "main\n") })
        defer { fixture.remove() }

        let commits = try await fixture.repository.conflictCommits(touching: ["f.txt"])

        XCTAssertEqual(Set(commits.map(\.id)), Set([try fixture.git("rev-parse", "HEAD"), try fixture.git("rev-parse", "MERGE_HEAD")]))
    }

    // MARK: Renames

    func testRenameConflictsListEachPathWithItsOwnStages() async throws {
        let lines = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let fixture = try merge(
            base: { try $0.write("a.txt", lines); try $0.write("r.txt", lines) },
            feature: { try $0.git("mv", "a.txt", "a-feature.txt"); try $0.git("mv", "r.txt", "r-feature.txt") },
            main: { try $0.git("mv", "a.txt", "a-main.txt"); try $0.git("rm", "-q", "r.txt") })
        defer { fixture.remove() }
        let repo = fixture.repository

        let stages = try await repo.conflictStages()
        XCTAssertEqual(stages["a.txt"]?.kind, .bothDeleted, "rename/rename leaves the old path deleted on both sides")
        XCTAssertEqual(stages["a-main.txt"]?.kind, .addedByUs)
        XCTAssertEqual(stages["a-feature.txt"]?.kind, .addedByThem)
        XCTAssertEqual(stages["r-feature.txt"]?.kind, .deletedByUs, "rename/delete keeps the base at the new path")

        let oldPath = try await repo.conflict(at: "a.txt")
        XCTAssertEqual(oldPath.content, .none)
        let renamed = try await repo.conflict(at: "a-main.txt")
        XCTAssertEqual(renamed.content, .oneSided(remaining: lines))

        try await repo.resolveConflictsByDeleting(["a.txt"])
        try await repo.resolveConflicts(["a-main.txt"], taking: .ours)
        try await repo.resolveConflictsByDeleting(["a-feature.txt"])
        try await repo.resolveConflictsByDeleting(["r-feature.txt"])
        XCTAssertEqual(try unmerged(fixture), "")
        XCTAssertEqual(try fixture.git("ls-files"), "a-main.txt")
    }

    // MARK: Binary

    func testBinaryConflictOffersWholeSides() async throws {
        let fixture = try merge(
            base: { try self.writeData($0, "b.bin", Data([0, 1, 2])) },
            feature: { try self.writeData($0, "b.bin", Data([0, 1, 3])); try $0.write("t.txt", "feature\n") },
            main: { try self.writeData($0, "b.bin", Data([0, 1, 4])); try $0.write("t.txt", "main\n") })
        defer { fixture.remove() }
        let repo = fixture.repository
        let binary = try await repo.binaryConflictPaths()
        XCTAssertEqual(binary, ["b.bin"])

        let conflict = try await repo.conflict(at: "b.bin")
        XCTAssertEqual(conflict.kind, .bothModified)
        XCTAssertEqual(conflict.content, .binary)
        try await repo.resolveConflicts(["b.bin"], taking: .theirs)
        XCTAssertEqual(try unmerged(fixture), "t.txt", "the text conflict stays open")
        XCTAssertEqual(try readData(fixture, "b.bin"), Data([0, 1, 3]))
    }

    func testAPathWithoutConflictThrows() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        do {
            _ = try await fixture.repository.conflict(at: "file.txt")
            XCTFail("a resolved path has no conflict")
        } catch let error as NoConflict {
            XCTAssertEqual(error.path, "file.txt")
        }
    }

    // MARK: Merge tool

    func testMergeToolPrefersTheGuiTool() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("base")
        // The user's own config could name a tool; the repository's settings win over it.
        try fixture.git("config", "merge.tool", "vimdiff")
        let terminalOnly = await fixture.repository.mergeToolName()
        XCTAssertEqual(terminalOnly, "vimdiff", "without merge.guitool, git mergetool --gui falls back to merge.tool")
        try fixture.git("config", "merge.guitool", "opendiff")
        let gui = await fixture.repository.mergeToolName()
        XCTAssertEqual(gui, "opendiff")
    }

    func testChoosingTheGlobalGuiToolWritesOnlyTheGivenGlobalConfig() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let global = folder.url.appendingPathComponent("gitconfig").path
        FileManager.default.createFile(atPath: global, contents: Data("[user]\n\tname = Someone\n".utf8))
        let environment = ["GIT_CONFIG_GLOBAL": global]
        let before = try await MergeTools.globalGuiTool(environment: environment)
        XCTAssertNil(before)
        try await MergeTools.setGlobalGuiTool("opendiff", environment: environment)
        let after = try await MergeTools.globalGuiTool(environment: environment)
        XCTAssertEqual(after, "opendiff")
        let written = try String(contentsOfFile: global, encoding: .utf8)
        XCTAssertTrue(written.contains("name = Someone"), "the rest of the global config stays")
    }
}

/// `git mergetool --tool-help`, as git 2.5x prints it in the C locale.
final class MergeToolParserTests: XCTestCase {
    func testToolHelpSeparatesGraphicalAvailableAndUserDefinedTools() {
        let output = """
        'git mergetool --tool=<tool>' may be set to one of the following:
        \t\topendiff         Use FileMerge (requires a graphical session)
        \t\tvimdiff          Use Vim with a custom layout (see `git help mergetool`'s `BACKEND SPECIFIC HINTS` section)

        \tuser-defined:
        \t\tmytool.cmd mytool --merge "$LOCAL" "$REMOTE" -o "$MERGED"

        The following tools are valid, but not currently available:
        \t\tmeld             Use Meld (requires a graphical session) with optional `auto merge` (see `git help mergetool`'s `CONFIGURATION` section)
        \t\tnvimdiff         Use Neovim with a custom layout (see `git help mergetool`'s `BACKEND SPECIFIC HINTS` section)

        Some of the tools listed above only work in a windowed
        environment. If run in a terminal-only session, they will fail.
        """
        let tools = MergeToolParser.parseToolHelp(output)
        XCTAssertEqual(tools.map(\.name), ["opendiff", "vimdiff", "mytool", "meld", "nvimdiff"])
        XCTAssertEqual(tools.filter(\.isGraphical).map(\.name), ["opendiff", "mytool", "meld"])
        XCTAssertEqual(tools.filter(\.isAvailable).map(\.name), ["opendiff", "vimdiff", "mytool"])
        XCTAssertEqual(tools.first?.summary, "Use FileMerge")
        XCTAssertEqual(tools[2].summary, #"mytool --merge "$LOCAL" "$REMOTE" -o "$MERGED""#)
        XCTAssertTrue(tools[2].isUserDefined)
        XCTAssertTrue(tools[3].summary.hasPrefix("Use Meld with optional"))
    }

    func testToolHelpOfTheInstalledGitIsRead() async throws {
        let tools = try await MergeTools.all()
        XCTAssertTrue(tools.contains { $0.name == "vimdiff" && !$0.isGraphical }, "git always knows vimdiff")
        XCTAssertTrue(tools.contains { $0.name == "opendiff" && $0.isGraphical })
    }
}

private extension Data {
    /// The text re-encoded as ISO Latin 1.
    var latin1: Data { String(decoding: self, as: UTF8.self).data(using: .isoLatin1)! }
}

/// Building a result change by change, without a repository.
final class MergeResolutionTests: XCTestCase {
    private let document = MergeDocument(regions: [
        .same(["a"]),
        .change(MergeChange(base: ["b"], ours: ["b ours"], theirs: ["b theirs"], kind: .conflict)),
        .same(["c"]),
        .change(MergeChange(base: ["d"], ours: ["d"], theirs: ["d theirs"], kind: .theirs)),
    ], encoding: .utf8, endsWithNewline: true)

    func testChangesOfOneSideStartTakenAndConflictsOpen() {
        let resolution = MergeResolution(document: document)
        XCTAssertEqual(resolution.openConflicts, 1)
        XCTAssertNil(resolution.result(at: 0))
        XCTAssertEqual(resolution.result(at: 1), ["d theirs"])
        XCTAssertNil(resolution.text)
    }

    func testTakingBothSidesKeepsTheOrderOfTheClicks() {
        var resolution = MergeResolution(document: document)
        resolution.take(.theirs, at: 0)
        resolution.take(.ours, at: 0)
        XCTAssertEqual(resolution.result(at: 0), ["b theirs", "b ours"])
        resolution.take(.theirs, at: 0)
        XCTAssertEqual(resolution.result(at: 0), ["b theirs", "b ours"], "taking a side twice does not repeat it")
        XCTAssertEqual(resolution.text, "a\nb theirs\nb ours\nc\nd theirs\n")
    }

    func testIgnoringEveryTakenSideKeepsTheBase() {
        var resolution = MergeResolution(document: document)
        resolution.ignore(.ours, at: 0)
        XCTAssertTrue(resolution.isResolved(0), "ignoring one side decides the conflict")
        XCTAssertEqual(resolution.result(at: 0), ["b"])
        resolution.ignore(.theirs, at: 1)
        XCTAssertEqual(resolution.result(at: 1), ["d"], "a change of one side can be undone")
    }

    func testWordMergeReplacesTheSidesUntilASideIsTakenAgain() {
        var resolution = MergeResolution(document: document)
        resolution.setMerged(["b both"], at: 0)
        XCTAssertEqual(resolution.result(at: 0), ["b both"])
        resolution.take(.ours, at: 0)
        XCTAssertEqual(resolution.result(at: 0), ["b ours"])
    }

    func testWholeFileChoiceOnlyTouchesOpenConflicts() {
        var resolution = MergeResolution(document: document)
        resolution.ignore(.theirs, at: 1)
        resolution.takeInOpenConflicts([.ours, .theirs])
        XCTAssertEqual(resolution.result(at: 0), ["b ours", "b theirs"])
        XCTAssertEqual(resolution.result(at: 1), ["d"])
    }

    func testStatesFromAnotherDocumentAreDropped() {
        var earlier = MergeResolution(document: document)
        earlier.take(.ours, at: 0)
        XCTAssertEqual(MergeResolution(document: document, states: earlier.states).result(at: 0), ["b ours"])
        XCTAssertNil(MergeResolution(document: document, states: [earlier.states[0]]).result(at: 0))
    }
}
