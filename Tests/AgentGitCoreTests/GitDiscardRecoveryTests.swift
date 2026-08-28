import Foundation
import XCTest
@testable import AgentGitCore

final class GitDiscardRecoveryTests: XCTestCase {
    func testCopiesTrackedItemWithRecoveryMetadata() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentgit-recovery-copy-\(UUID().uuidString)",
            isDirectory: true
        )
        let worktree = container.appendingPathComponent("worktree", isDirectory: true)
        let recovery = container.appendingPathComponent("recovery", isDirectory: true)
        let source = worktree.appendingPathComponent("Sources/Feature.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("working contents\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: container) }
        let store = GitDiscardRecoveryStore(destination: .directory(recovery))

        let bundle = try store.preserve(
            itemAt: source,
            worktreeURL: worktree,
            relativePath: "Sources/Feature.swift",
            kind: .selection,
            movesOriginal: false
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let recovered = bundle.appendingPathComponent("Files/Sources/Feature.swift")
        XCTAssertEqual(try Data(contentsOf: recovered), try Data(contentsOf: source))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            GitDiscardRecoveryMetadata.self,
            from: Data(contentsOf: bundle.appendingPathComponent("Recovery.json"))
        )
        XCTAssertEqual(metadata.worktreePath, worktree.standardizedFileURL.path)
        XCTAssertEqual(metadata.relativePath, "Sources/Feature.swift")
        XCTAssertEqual(metadata.kind, .selection)
    }

    func testMovesUntrackedDirectoryIntoRecoveryBundle() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentgit-recovery-move-\(UUID().uuidString)",
            isDirectory: true
        )
        let worktree = container.appendingPathComponent("worktree", isDirectory: true)
        let recovery = container.appendingPathComponent("recovery", isDirectory: true)
        let source = worktree.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data("generated\n".utf8).write(
            to: source.appendingPathComponent("output.txt")
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let store = GitDiscardRecoveryStore(destination: .directory(recovery))

        let bundle = try store.preserve(
            itemAt: source,
            worktreeURL: worktree,
            relativePath: "Generated",
            kind: .file,
            movesOriginal: true
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: bundle.appendingPathComponent(
                        "Files/Generated/output.txt"
                    )
                ),
                as: UTF8.self
            ),
            "generated\n"
        )
    }

    func testDestinationFailureLeavesOriginalItemInPlace() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentgit-recovery-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        let worktree = container.appendingPathComponent("worktree", isDirectory: true)
        let source = worktree.appendingPathComponent("temporary.txt")
        let blockingDestination = container.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(
            at: worktree,
            withIntermediateDirectories: true
        )
        try Data("temporary\n".utf8).write(to: source)
        try Data("not a directory\n".utf8).write(to: blockingDestination)
        defer { try? FileManager.default.removeItem(at: container) }
        let store = GitDiscardRecoveryStore(
            destination: .directory(blockingDestination)
        )

        XCTAssertThrowsError(
            try store.preserve(
                itemAt: source,
                worktreeURL: worktree,
                relativePath: "temporary.txt",
                kind: .file,
                movesOriginal: true
            )
        )
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: source), as: UTF8.self),
            "temporary\n"
        )
    }

    func testSystemTrashDestinationCreatesRecoverableBundle() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agentgit-recovery-trash-\(UUID().uuidString)",
            isDirectory: true
        )
        let worktree = container.appendingPathComponent("worktree", isDirectory: true)
        let source = worktree.appendingPathComponent("temporary.txt")
        try FileManager.default.createDirectory(
            at: worktree,
            withIntermediateDirectories: true
        )
        try Data("temporary\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: container) }

        let trashedBundle = try GitDiscardRecoveryStore.systemTrash.preserve(
            itemAt: source,
            worktreeURL: worktree,
            relativePath: "temporary.txt",
            kind: .file,
            movesOriginal: true
        )
        defer { try? FileManager.default.removeItem(at: trashedBundle) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            String(
                decoding: try Data(
                    contentsOf: trashedBundle.appendingPathComponent(
                        "Files/temporary.txt"
                    )
                ),
                as: UTF8.self
            ),
            "temporary\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: trashedBundle.appendingPathComponent("Recovery.json").path
            )
        )
    }
}
