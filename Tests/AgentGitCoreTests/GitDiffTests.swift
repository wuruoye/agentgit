import Foundation
import XCTest
@testable import AgentGitCore

final class GitDiffTests: XCTestCase {
    private func change(_ path: String) -> GitFileChange {
        GitFileChange(
            path: path,
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
    }

    /// 没有 hunk 的三种原因必须能分辨，否则 UI 只能显示“什么都没有”。
    func testReportsBinaryStateInsteadOfEmptyDiff() throws {
        let patch = """
        diff --git a/assets/logo.png b/assets/logo.png
        index 1111111..2222222 100644
        Binary files a/assets/logo.png and b/assets/logo.png differ
        """

        let diff = try UnifiedDiffParser.parse(
            Data(patch.utf8),
            change: change("assets/logo.png"),
            scope: .working
        )

        XCTAssertEqual(diff.state, .binary)
        XCTAssertEqual(diff.state.note, "Binary file")
        XCTAssertTrue(diff.hunks.isEmpty)
    }

    func testReportsTooLargeStateAndKeepsLineCounts() throws {
        let bodyLineCount = UnifiedDiffParser.maximumRenderedLines + 10
        var patch = """
        diff --git a/huge.txt b/huge.txt
        index 1111111..2222222 100644
        --- a/huge.txt
        +++ b/huge.txt
        @@ -1,0 +1,\(bodyLineCount) @@

        """
        patch += (0..<bodyLineCount).map { "+line \($0)" }.joined(separator: "\n")

        let diff = try UnifiedDiffParser.parse(
            Data(patch.utf8),
            change: change("huge.txt"),
            scope: .working
        )

        XCTAssertEqual(diff.state, .tooLarge(lineCount: bodyLineCount))
        XCTAssertTrue(diff.hunks.isEmpty, "过大的文件不应构造行对象")
        XCTAssertEqual(diff.addedLineCount, bodyLineCount, "计数仍要保留，文件头还得显示增删")
        XCTAssertEqual(diff.deletedLineCount, 0)
    }

    func testKeepsTextualStateForNormalDiff() throws {
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,2 @@
         first
        +second
        """

        let diff = try UnifiedDiffParser.parse(
            Data(patch.utf8),
            change: change("a.txt"),
            scope: .working
        )

        XCTAssertEqual(diff.state, .textual)
        XCTAssertNil(diff.state.note)
        XCTAssertEqual(diff.addedLineCount, 1)
    }

    func testReportsModeAndRenameOnlyChangesAsMetadata() throws {
        let modePatch = """
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755
        """
        let renameChange = GitFileChange(
            path: "new-name.txt",
            originalPath: "old-name.txt",
            indexStatus: "R",
            worktreeStatus: ".",
            kind: .renamedOrCopied
        )
        let renamePatch = """
        diff --git a/old-name.txt b/new-name.txt
        similarity index 100%
        rename from old-name.txt
        rename to new-name.txt
        """

        let modeDiff = try UnifiedDiffParser.parse(
            Data(modePatch.utf8),
            change: change("script.sh"),
            scope: .working
        )
        let renameDiff = try UnifiedDiffParser.parse(
            Data(renamePatch.utf8),
            change: renameChange,
            scope: .staged
        )

        XCTAssertEqual(
            modeDiff.state,
            .metadata("old mode 100644 · new mode 100755")
        )
        XCTAssertEqual(
            renameDiff.state,
            .metadata(
                "similarity index 100% · rename from old-name.txt · rename to new-name.txt"
            )
        )
        XCTAssertTrue(modeDiff.hunks.isEmpty)
        XCTAssertTrue(renameDiff.hunks.isEmpty)
    }

    func testParserStopsWhenTaskIsAlreadyCancelled() async {
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let targetChange = change("a.txt")
        let task = Task.detached {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try UnifiedDiffParser.parse(
                Data(patch.utf8),
                change: targetChange,
                scope: .working
            )
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled parsing should throw CancellationError")
        } catch is CancellationError {
            return
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testParsesHunkLineNumbersAndChangeCounts() throws {
        let change = GitFileChange(
            path: "Sources/Feature.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let patch = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        index 1111111..2222222 100644
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -1,3 +1,4 @@ func feature() {
         first
        -old
        +new
        +added
         last
        \\ No newline at end of file
        """

        let diff = try UnifiedDiffParser.parse(
            Data(patch.utf8),
            change: change,
            scope: .working
        )

        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.addedLineCount, 2)
        XCTAssertEqual(diff.deletedLineCount, 1)
        XCTAssertEqual(diff.hunks[0].sectionHeading, "func feature() {")
        XCTAssertEqual(diff.hunks[0].lines[0].oldLineNumber, 1)
        XCTAssertEqual(diff.hunks[0].lines[0].newLineNumber, 1)
        XCTAssertEqual(diff.hunks[0].lines[1].oldLineNumber, 2)
        XCTAssertNil(diff.hunks[0].lines[1].newLineNumber)
        XCTAssertNil(diff.hunks[0].lines[2].oldLineNumber)
        XCTAssertEqual(diff.hunks[0].lines[2].newLineNumber, 2)
        XCTAssertEqual(diff.hunks[0].lines.last?.kind, .metadata)
    }

    func testRenderIDTracksVisibleDiffContentAndStatistics() {
        let targetChange = change("Sources/Feature.swift")
        let originalLine = GitDiffLine(
            id: 0,
            kind: .addition,
            oldLineNumber: nil,
            newLineNumber: 1,
            content: "let value = 1"
        )
        let highlightedLine = GitDiffLine(
            id: 0,
            kind: .addition,
            oldLineNumber: nil,
            newLineNumber: 1,
            content: "let value = 1",
            inlineRanges: [GitDiffInlineRange(location: 4, length: 5)]
        )
        func diff(line: GitDiffLine, addedLineCount: Int = 1) -> GitFileDiff {
            GitFileDiff(
                change: targetChange,
                scope: .working,
                hunks: [
                    GitDiffHunk(
                        id: 0,
                        header: "@@ -0,0 +1 @@",
                        oldStart: 0,
                        oldCount: 0,
                        newStart: 1,
                        newCount: 1,
                        lines: [line]
                    )
                ],
                state: .textual,
                addedLineCount: addedLineCount,
                deletedLineCount: 0
            )
        }

        XCTAssertEqual(diff(line: originalLine).renderID, diff(line: originalLine).renderID)
        XCTAssertNotEqual(diff(line: originalLine).renderID, diff(line: highlightedLine).renderID)
        XCTAssertNotEqual(
            diff(line: originalLine).renderID,
            diff(line: originalLine, addedLineCount: 2).renderID
        )
    }

    func testKeepsSeparateGitHunksAndTheirSectionHeadings() throws {
        let change = GitFileChange(
            path: "Sources/Feature.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let patch = """
        diff --git a/Sources/Feature.swift b/Sources/Feature.swift
        index 1111111..2222222 100644
        --- a/Sources/Feature.swift
        +++ b/Sources/Feature.swift
        @@ -2,3 +2,3 @@ func firstFeature() {
         before
        -oldFirst
        +newFirst
         after
        @@ -20,3 +20,3 @@ func secondFeature() {
         before
        -oldSecond
        +newSecond
         after
        """

        let diff = try UnifiedDiffParser.parse(
            Data(patch.utf8),
            change: change,
            scope: .working
        )

        XCTAssertEqual(diff.hunks.map(\.id), [0, 1])
        XCTAssertEqual(
            diff.hunks.map(\.sectionHeading),
            ["func firstFeature() {", "func secondFeature() {"]
        )
        XCTAssertEqual(diff.hunks.map(\.newStart), [2, 20])
        XCTAssertEqual(diff.hunks.map(\.newCount), [3, 3])
    }

    func testCreatesReviewableDiffForUntrackedTextFile() {
        let change = GitFileChange(
            path: "notes.txt",
            originalPath: nil,
            indexStatus: "?",
            worktreeStatus: "?",
            kind: .untracked
        )

        let diff = UnifiedDiffParser.addedFile(
            data: Data("one\ntwo\n".utf8),
            change: change
        )

        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.addedLineCount, 2)
        XCTAssertEqual(diff.hunks[0].lines.map(\.newLineNumber), [1, 2])
    }

    func testParsesMultipleFileDiffsInChangeOrder() throws {
        let changes = [
            GitFileChange(
                path: "folder/first.txt",
                originalPath: nil,
                indexStatus: "M",
                worktreeStatus: "M",
                kind: .ordinary
            ),
            GitFileChange(
                path: "second.txt",
                originalPath: nil,
                indexStatus: "D",
                worktreeStatus: "D",
                kind: .ordinary
            )
        ]
        let patch = """
        diff --git a/second.txt b/second.txt
        deleted file mode 100644
        --- a/second.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git a/folder/first.txt b/folder/first.txt
        --- a/folder/first.txt
        +++ b/folder/first.txt
        @@ -1 +1,2 @@
         base
        +added
        """

        let diffs = try UnifiedDiffParser.parseFiles(
            Data(patch.utf8),
            changes: changes,
            scope: .staged
        )

        XCTAssertEqual(diffs.map(\.change.path), ["folder/first.txt", "second.txt"])
        XCTAssertEqual(diffs.map(\.addedLineCount), [1, 0])
        XCTAssertEqual(diffs.map(\.deletedLineCount), [0, 2])
    }

    /// 未跟踪目录里有嵌套仓库（submodule 或 linked worktree）时，`git ls-files --others`
    /// 不会走进去，只报那个目录本身。loadDiff 拿目录路径去读文件会抛 POSIX 21
    /// "Is a directory"，整个 Review 面板就只剩一段 NSError。
    func testUntrackedNestedRepositoryIsUnavailableInsteadOfThrowing() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-nested-repo-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        let outer = repository.appendingPathComponent("outer")
        let nested = outer.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let runner = GitCommandRunner()
        for directory in [repository, nested] {
            _ = try await runner.run(arguments: ["init", "-b", "main"], workingDirectory: directory)
            _ = try await runner.run(
                arguments: ["config", "user.name", "AgentGit Tests"],
                workingDirectory: directory
            )
            _ = try await runner.run(
                arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
                workingDirectory: directory
            )
        }
        try Data("base\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        _ = try await runner.run(arguments: ["add", "file.txt"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
        // outer/ 未跟踪，里面既有普通文件、又有一个嵌套仓库。
        try Data("note one\nnote two\n".utf8).write(to: outer.appendingPathComponent("note.txt"))
        try Data("inner\n".utf8).write(to: nested.appendingPathComponent("inner.txt"))

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let nestedChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path.hasPrefix("outer/nested") }
        )
        let noteChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "outer/note.txt" }
        )

        let nestedDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: nestedChange,
            scope: .working
        )
        XCTAssertEqual(nestedDiff.state, .unavailable("Nested Git repository"))

        // 普通未跟踪文件仍要正常出 diff —— 不能靠「把目录条目整个丢掉」来绕过。
        let noteDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: noteChange,
            scope: .working
        )
        XCTAssertEqual(noteDiff.addedLineCount, 2)
    }

    func testLoadsWorkingStagedAndUntrackedDiffsFromGit() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-diff-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: container)
        }

        let runner = GitCommandRunner()
        _ = try await runner.run(arguments: ["init", "-b", "main"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )

        let trackedFile = repository.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: trackedFile)
        _ = try await runner.run(arguments: ["add", "file.txt"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )

        try Data("base\nstaged\n".utf8).write(to: trackedFile)
        _ = try await runner.run(arguments: ["add", "file.txt"], workingDirectory: repository)
        try Data("base\nstaged\nworking\n".utf8).write(to: trackedFile)
        try Data("untracked one\nuntracked two\n".utf8).write(
            to: repository.appendingPathComponent("new.txt")
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let trackedChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "file.txt" }
        )
        let untrackedChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "new.txt" }
        )

        let workingDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: trackedChange,
            scope: .working
        )
        let stagedDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: trackedChange,
            scope: .staged
        )
        let untrackedDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: untrackedChange,
            scope: .working
        )

        XCTAssertEqual(workingDiff.addedLineCount, 1)
        XCTAssertEqual(workingDiff.hunks[0].lines.first(where: { $0.kind == .addition })?.content, "working")
        XCTAssertEqual(stagedDiff.addedLineCount, 1)
        XCTAssertEqual(stagedDiff.hunks[0].lines.first(where: { $0.kind == .addition })?.content, "staged")
        XCTAssertEqual(untrackedDiff.addedLineCount, 2)

        let workingDiffs = try await service.loadDiffs(
            worktree: worktree.worktree,
            changes: [trackedChange, untrackedChange],
            scope: .working
        )
        let stagedDiffs = try await service.loadDiffs(
            worktree: worktree.worktree,
            changes: [trackedChange],
            scope: .staged
        )
        XCTAssertEqual(workingDiffs.map(\.addedLineCount), [1, 2])
        XCTAssertEqual(stagedDiffs.map(\.addedLineCount), [1])
    }

    func testLoadsModeAndRenameOnlyMetadataFromRealGitRepository() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-metadata-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let runner = GitCommandRunner()
        _ = try await runner.run(
            arguments: ["init", "-b", "main"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "core.fileMode", "true"],
            workingDirectory: repository
        )
        let scriptURL = repository.appendingPathComponent("script.sh")
        try Data("echo metadata\n".utf8).write(to: scriptURL)
        try Data("rename\n".utf8).write(
            to: repository.appendingPathComponent("old-name.txt")
        )
        _ = try await runner.run(arguments: ["add", "."], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial metadata files"],
            workingDirectory: repository
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        _ = try await runner.run(
            arguments: ["mv", "old-name.txt", "new-name.txt"],
            workingDirectory: repository
        )

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let modeChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "script.sh" }
        )
        let renameChange = try XCTUnwrap(
            worktree.status.changes.first { $0.path == "new-name.txt" }
        )
        let modeDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: modeChange,
            scope: .working
        )
        let renameDiff = try await service.loadDiff(
            worktree: worktree.worktree,
            change: renameChange,
            scope: .staged
        )

        XCTAssertEqual(
            modeDiff.state,
            .metadata("old mode 100644 · new mode 100755")
        )
        XCTAssertEqual(
            renameDiff.state,
            .metadata(
                "similarity index 100% · rename from old-name.txt · rename to new-name.txt"
            )
        )
    }

    func testLoadsAllCommitDiffsWithOneReviewRequest() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentgit-commit-review-test-\(UUID().uuidString)")
        let repository = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: container)
        }

        let runner = GitCommandRunner()
        _ = try await runner.run(arguments: ["init", "-b", "main"], workingDirectory: repository)
        _ = try await runner.run(
            arguments: ["config", "user.name", "AgentGit Tests"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["config", "user.email", "agentgit-tests@example.invalid"],
            workingDirectory: repository
        )

        try Data("one\n".utf8).write(to: repository.appendingPathComponent("first.txt"))
        try Data("two\n".utf8).write(to: repository.appendingPathComponent("second.txt"))
        _ = try await runner.run(arguments: ["add", "."], workingDirectory: repository)
        _ = try await runner.run(arguments: ["commit", "-m", "Initial"], workingDirectory: repository)

        try Data("one\nadded\n".utf8).write(to: repository.appendingPathComponent("first.txt"))
        try FileManager.default.removeItem(at: repository.appendingPathComponent("second.txt"))
        _ = try await runner.run(arguments: ["add", "-A"], workingDirectory: repository)
        _ = try await runner.run(arguments: ["commit", "-m", "Review target"], workingDirectory: repository)

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let worktree = try XCTUnwrap(project.worktrees.first)
        let history = try await service.loadHistory(worktree: worktree.worktree)
        let commit = try XCTUnwrap(history.first)
        let changes = try await service.loadCommitChanges(
            worktree: worktree.worktree,
            commit: commit
        )
        let diffs = try await service.loadCommitDiffs(
            worktree: worktree.worktree,
            commit: commit,
            changes: changes
        )

        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs.reduce(0) { $0 + $1.addedLineCount }, 1)
        XCTAssertEqual(diffs.reduce(0) { $0 + $1.deletedLineCount }, 1)
    }
}
