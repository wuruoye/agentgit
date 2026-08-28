import AgentGitCore
import Foundation
import XCTest
@testable import AgentGitApp

final class ReviewContentStoreTests: XCTestCase {
    func testPartialPendingDiffCacheSurvivesRestartWithoutClaimingCompletion() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-partial-pending-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = makeSnapshot(activityAt: Date(timeIntervalSince1970: 300))
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        let key = PendingReviewContentCacheKey(
            snapshot: snapshot,
            options: options
        )
        let diff = makeDiff(change: try XCTUnwrap(snapshot.status.changes.first))
        let writer = ReviewContentStore(directoryURL: directory)

        try await writer.savePartialPendingDiffs([diff], for: key)

        let partialReader = ReviewContentStore(directoryURL: directory)
        let partialContent = try XCTUnwrap(
            partialReader.startupContent(snapshot: snapshot, options: options)
        )
        XCTAssertEqual(partialContent.pendingDiffs, [diff])
        XCTAssertFalse(partialContent.pendingDiffsAreComplete)
        let partialDiffs = await partialReader.pendingDiffs(for: key)
        XCTAssertEqual(partialDiffs, [diff])
        let partialEntry = await partialReader.pendingDiffEntry(for: key)
        XCTAssertEqual(
            partialEntry,
            ReviewDiffCacheEntry(diffs: [diff], isComplete: false)
        )

        let manifestURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: {
                $0.lastPathComponent.hasPrefix("pending-manifest-")
            })
        )
        let manifestData = try Data(contentsOf: manifestURL)
        var legacyManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        legacyManifest["isComplete"] = nil
        try JSONSerialization.data(
            withJSONObject: legacyManifest,
            options: [.sortedKeys]
        ).write(to: manifestURL, options: .atomic)
        let legacyReader = ReviewContentStore(directoryURL: directory)
        let legacyContent = try XCTUnwrap(
            legacyReader.startupContent(snapshot: snapshot, options: options)
        )
        XCTAssertTrue(legacyContent.pendingDiffsAreComplete)
        let legacyEntry = await legacyReader.pendingDiffEntry(for: key)
        XCTAssertEqual(
            legacyEntry,
            ReviewDiffCacheEntry(diffs: [diff], isComplete: true)
        )

        try await writer.savePendingDiffs([diff], for: key)

        let completeReader = ReviewContentStore(directoryURL: directory)
        let completeContent = try XCTUnwrap(
            completeReader.startupContent(snapshot: snapshot, options: options)
        )
        XCTAssertEqual(completeContent.pendingDiffs, [diff])
        XCTAssertTrue(completeContent.pendingDiffsAreComplete)
        let completeEntry = await completeReader.pendingDiffEntry(for: key)
        XCTAssertEqual(
            completeEntry,
            ReviewDiffCacheEntry(diffs: [diff], isComplete: true)
        )
    }

    func testPartialHistoricalDiffCacheSurvivesRestartAndReadsLegacyManifest() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-partial-history-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = makeSnapshot(activityAt: Date(timeIntervalSince1970: 300))
        let context = ReviewContext.commit(String(repeating: "c", count: 40))
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        let key = try XCTUnwrap(
            HistoricalReviewDiffCacheKey(
                worktreeID: snapshot.id,
                context: context,
                options: options
            )
        )
        let change = try XCTUnwrap(snapshot.status.changes.first)
        let diff = makeDiff(
            change: change,
            scope: .staged
        )
        let writer = ReviewContentStore(directoryURL: directory)

        try await writer.savePartialHistoricalDiffs([diff], for: key)
        let details = HistoricalReviewDetails(
            message: "Cached commit details",
            changes: [change]
        )
        try await writer.saveHistoricalDetails(
            details,
            for: try XCTUnwrap(
                HistoricalReviewDetailsCacheKey(
                    worktreeID: snapshot.id,
                    context: context
                )
            )
        )

        let partialReader = ReviewContentStore(directoryURL: directory)
        let startupContent = try XCTUnwrap(
            partialReader.startupContent(
                snapshot: snapshot,
                options: options,
                historicalContext: context
            )
        )
        XCTAssertEqual(startupContent.historicalContext, context)
        XCTAssertEqual(startupContent.historicalDetails, details)
        XCTAssertEqual(startupContent.historicalDiffs, [diff])
        XCTAssertFalse(startupContent.historicalDiffsAreComplete)
        XCTAssertNil(startupContent.pendingDiffs)
        let restoredPartialDiffs = await partialReader.historicalDiffs(for: key)
        XCTAssertEqual(restoredPartialDiffs, [diff])
        let partialEntry = await partialReader.historicalDiffEntry(for: key)
        XCTAssertEqual(
            partialEntry,
            ReviewDiffCacheEntry(diffs: [diff], isComplete: false)
        )
        let manifestURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: {
                $0.lastPathComponent.hasPrefix("historical-diff-manifest-")
            })
        )
        let manifestData = try Data(contentsOf: manifestURL)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        XCTAssertEqual(manifest["isComplete"] as? Bool, false)
        manifest["isComplete"] = nil
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: manifestURL, options: .atomic)

        let legacyReader = ReviewContentStore(directoryURL: directory)
        let restoredLegacyDiffs = await legacyReader.historicalDiffs(for: key)
        XCTAssertEqual(restoredLegacyDiffs, [diff])
        let legacyEntry = await legacyReader.historicalDiffEntry(for: key)
        XCTAssertEqual(
            legacyEntry,
            ReviewDiffCacheEntry(diffs: [diff], isComplete: true)
        )
    }

    func testMigratesLegacyHistoryCacheIntoSmallerStartupPage() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-history-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = makeSnapshot(activityAt: Date(timeIntervalSince1970: 300))
        let legacyKey = HistoryReviewContentCacheKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID,
            pageSize: 200
        )
        let commits = (0..<200).map { index in
            let oid = String(format: "%040x", index + 1)
            return GitCommit(
                oid: oid,
                shortOID: String(oid.prefix(7)),
                authorName: "AgentGit Tests",
                authoredAt: Date(timeIntervalSince1970: TimeInterval(index)),
                parentOIDs: [],
                refNames: [],
                subject: "Cached commit \(index + 1)"
            )
        }
        let writer = ReviewContentStore(directoryURL: directory)
        try await writer.saveHistoryPage(
            GitHistoryPage(commits: commits, nextOffset: 200, hasMore: false),
            for: legacyKey
        )

        let startupReader = ReviewContentStore(directoryURL: directory)
        let startupContent = try XCTUnwrap(
            startupReader.startupContent(
                snapshot: snapshot,
                options: GitDiffOptions()
            )
        )
        let startupPage = try XCTUnwrap(startupContent.historyPage)
        XCTAssertEqual(startupPage.commits, Array(commits.prefix(100)))
        XCTAssertEqual(startupPage.nextOffset, 100)
        XCTAssertTrue(startupPage.hasMore)

        let currentKey = HistoryReviewContentCacheKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID,
            pageSize: StartupReviewContent.historyPageSize
        )
        let migratedPage = await startupReader.historyPage(for: currentKey)
        XCTAssertEqual(migratedPage, startupPage)
        let persistedReader = ReviewContentStore(directoryURL: directory)
        let persistedPage = await persistedReader.historyPage(for: currentKey)
        XCTAssertEqual(persistedPage, startupPage)
    }

    func testMemoryCacheEvictsLeastRecentlyUsedEntryAcrossReviewKinds() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-memory-lru-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewContentStore(
            directoryURL: directory,
            maximumMemoryCacheByteCount: 10 * 1_024 * 1_024,
            maximumMemoryCacheEntryCount: 2
        )
        let firstKey = HistoryReviewContentCacheKey(
            worktreeID: "/worktrees/first",
            revision: String(repeating: "a", count: 40),
            pageSize: 200
        )
        let secondKey = HistoryReviewContentCacheKey(
            worktreeID: "/worktrees/second",
            revision: String(repeating: "b", count: 40),
            pageSize: 200
        )
        let firstPage = makeHistoryPage(oidCharacter: "a", subject: "First")
        let secondPage = makeHistoryPage(oidCharacter: "b", subject: "Second")
        try await store.saveHistoryPage(firstPage, for: firstKey)
        try await store.saveHistoryPage(secondPage, for: secondKey)
        let firstLoadedPage = await store.historyPage(for: firstKey)
        XCTAssertEqual(firstLoadedPage, firstPage)

        let snapshot = makeSnapshot(activityAt: Date(timeIntervalSince1970: 300))
        let pendingKey = PendingReviewContentCacheKey(
            snapshot: snapshot,
            options: GitDiffOptions()
        )
        let pendingDiff = makeDiff(change: try XCTUnwrap(snapshot.status.changes.first))
        try await store.savePendingDiffs([pendingDiff], for: pendingKey)

        let firstIsRetained = await store.isHistoryPageInMemory(for: firstKey)
        let secondWasEvicted = await store.isHistoryPageInMemory(for: secondKey)
        let initialStats = await store.memoryCacheStats()
        XCTAssertTrue(firstIsRetained)
        XCTAssertFalse(secondWasEvicted)
        XCTAssertEqual(initialStats.entryCount, 2)
        let secondLoadedPage = await store.historyPage(for: secondKey)
        let firstWasEvicted = await store.isHistoryPageInMemory(for: firstKey)
        let secondIsRetained = await store.isHistoryPageInMemory(for: secondKey)
        let reloadedStats = await store.memoryCacheStats()
        XCTAssertEqual(secondLoadedPage, secondPage)
        XCTAssertFalse(firstWasEvicted)
        XCTAssertTrue(secondIsRetained)
        XCTAssertEqual(reloadedStats.entryCount, 2)
    }

    func testMemoryCacheReturnsButDoesNotRetainEntryAboveByteBudget() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-memory-budget-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = HistoryReviewContentCacheKey(
            worktreeID: "/worktrees/large",
            revision: String(repeating: "c", count: 40),
            pageSize: 200
        )
        let page = makeHistoryPage(
            oidCharacter: "c",
            subject: String(repeating: "Large subject ", count: 100)
        )
        let writer = ReviewContentStore(
            directoryURL: directory,
            maximumMemoryCacheByteCount: 64,
            maximumMemoryCacheEntryCount: 4
        )
        try await writer.saveHistoryPage(page, for: key)

        let writerStats = await writer.memoryCacheStats()
        XCTAssertEqual(writerStats, ReviewMemoryCacheStats(
            entryCount: 0,
            serializedByteCount: 0
        ))
        let reader = ReviewContentStore(
            directoryURL: directory,
            maximumMemoryCacheByteCount: 64,
            maximumMemoryCacheEntryCount: 4
        )
        let restoredPage = await reader.historyPage(for: key)
        let readerRetainedEntry = await reader.isHistoryPageInMemory(for: key)
        let readerStats = await reader.memoryCacheStats()
        XCTAssertEqual(restoredPage, page)
        XCTAssertFalse(readerRetainedEntry)
        XCTAssertEqual(readerStats.entryCount, 0)
    }

    func testReadsLargeRealDiffCacheWithinInteractiveBound() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-content-large-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheDirectory = container.appendingPathComponent("cache", isDirectory: true)
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
        let file = repository.appendingPathComponent("Large.swift")
        let original = (0..<10_000).map { "let value\($0) = \($0)\n" }.joined()
        try Data(original.utf8).write(to: file)
        _ = try await runner.run(
            arguments: ["add", "Large.swift"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add large file"],
            workingDirectory: repository
        )
        let changed = (0..<10_000).map { "let value\($0) = \($0 + 1)\n" }.joined()
        try Data(changed.utf8).write(to: file)

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let snapshot = try XCTUnwrap(project.worktrees.first)
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        let changes = snapshot.status.changes.filter(\.isUnstaged)
        let diffs = try await service.loadDiffs(
            worktree: snapshot.worktree,
            changes: changes,
            scope: .working,
            options: options
        )
        let key = PendingReviewContentCacheKey(snapshot: snapshot, options: options)
        let writer = ReviewContentStore(directoryURL: cacheDirectory)
        try await writer.savePendingDiffs(diffs, for: key)

        let reader = ReviewContentStore(directoryURL: cacheDirectory)
        let startedAt = ContinuousClock.now
        let restored = await reader.pendingDiffs(for: key)
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertEqual(restored, diffs)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testSegmentsRealPendingDiffBeyondAggregateAndStartupLimits() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-content-segmented-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheDirectory = container.appendingPathComponent("cache", isDirectory: true)
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
        let fileCount = 32
        let lineCount = 3_200
        let original = Data(
            String(
                repeating: String(repeating: "a", count: 96) + "\n",
                count: lineCount
            ).utf8
        )
        let changed = Data(
            String(
                repeating: String(repeating: "b", count: 96) + "\n",
                count: lineCount
            ).utf8
        )
        for index in 0..<fileCount {
            try original.write(
                to: repository.appendingPathComponent("Large\(index).txt")
            )
        }
        _ = try await runner.run(
            arguments: ["add", "."],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Add segmented cache fixtures"],
            workingDirectory: repository
        )
        for index in 0..<fileCount {
            try changed.write(
                to: repository.appendingPathComponent("Large\(index).txt")
            )
        }

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let snapshot = try XCTUnwrap(project.worktrees.first)
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        let changes = snapshot.status.changes.filter(\.isUnstaged)
        XCTAssertEqual(changes.count, fileCount)
        let diffs = try await service.loadDiffs(
            worktree: snapshot.worktree,
            changes: changes,
            scope: .working,
            options: options
        )
        XCTAssertEqual(diffs.count, fileCount)
        let key = PendingReviewContentCacheKey(snapshot: snapshot, options: options)
        let writer = ReviewContentStore(directoryURL: cacheDirectory)
        let partialDiffs = Array(diffs.prefix(24))
        try await writer.savePartialPendingDiffs(partialDiffs, for: key)
        let partialReader = ReviewContentStore(directoryURL: cacheDirectory)
        let restoredPartialDiffs = await partialReader.pendingDiffs(for: key)
        XCTAssertEqual(restoredPartialDiffs, partialDiffs)
        let partialStartupReader = ReviewContentStore(
            directoryURL: cacheDirectory
        )
        let partialStartupContent = try XCTUnwrap(
            partialStartupReader.startupContent(
                snapshot: snapshot,
                options: options
            )
        )
        XCTAssertFalse(partialStartupContent.pendingDiffsAreComplete)

        try await writer.savePendingDiffs(diffs, for: key)

        let cacheFiles = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let aggregateFiles = cacheFiles.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("pending-")
                && !name.hasPrefix("pending-file-")
                && !name.hasPrefix("pending-manifest-")
        }
        let manifestFiles = cacheFiles.filter {
            $0.lastPathComponent.hasPrefix("pending-manifest-")
        }
        let segmentedFiles = cacheFiles.filter {
            $0.lastPathComponent.hasPrefix("pending-file-")
        }
        XCTAssertTrue(aggregateFiles.isEmpty)
        XCTAssertEqual(manifestFiles.count, 1)
        XCTAssertEqual(segmentedFiles.count, fileCount)

        let startupReader = ReviewContentStore(directoryURL: cacheDirectory)
        let startupStartedAt = ContinuousClock.now
        let startupContent = try XCTUnwrap(
            startupReader.startupContent(snapshot: snapshot, options: options)
        )
        let startupElapsed = ContinuousClock.now - startupStartedAt
        let startupDiffs = try XCTUnwrap(startupContent.pendingDiffs)
        XCTAssertFalse(startupContent.pendingDiffsAreComplete)
        XCTAssertGreaterThan(startupDiffs.count, 0)
        XCTAssertLessThan(startupDiffs.count, fileCount)
        XCTAssertLessThan(startupElapsed, .seconds(1))

        let fullReader = ReviewContentStore(directoryURL: cacheDirectory)
        let restored = await fullReader.pendingDiffs(for: key)
        XCTAssertEqual(restored, diffs)
        let memoryStats = await fullReader.memoryCacheStats()
        XCTAssertEqual(memoryStats.entryCount, 0)
        XCTAssertLessThanOrEqual(
            memoryStats.serializedByteCount,
            16 * 1_024 * 1_024
        )

        let damagedFile = try XCTUnwrap(segmentedFiles.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.first)
        try Data("{invalid".utf8).write(to: damagedFile)
        let damagedStartupReader = ReviewContentStore(
            directoryURL: cacheDirectory
        )
        let damagedStartupContent = try XCTUnwrap(
            damagedStartupReader.startupContent(
                snapshot: snapshot,
                options: options
            )
        )
        XCTAssertFalse(damagedStartupContent.pendingDiffsAreComplete)
        let damagedReader = ReviewContentStore(directoryURL: cacheDirectory)
        let damagedDiffs = await damagedReader.pendingDiffs(for: key)
        XCTAssertNil(damagedDiffs)

        _ = try await runner.run(
            arguments: ["add", "."],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Commit large review"],
            workingDirectory: repository
        )
        let committedProject = try await service.loadProject(at: repository)
        let committedSnapshot = try XCTUnwrap(committedProject.worktrees.first)
        let committedHistory = try await service.loadHistoryPage(
            worktree: committedSnapshot.worktree,
            revision: committedSnapshot.worktree.headOID,
            offset: 0,
            pageSize: 20
        )
        let commit = try XCTUnwrap(committedHistory.commits.first)
        let parentOID = try XCTUnwrap(commit.parentOIDs.first)
        let commitChanges = try await service.loadCommitChanges(
            worktree: committedSnapshot.worktree,
            commit: commit
        )
        let commitDiffs = try await service.loadCommitDiffs(
            worktree: committedSnapshot.worktree,
            commit: commit,
            changes: commitChanges,
            options: options
        )
        XCTAssertEqual(commitDiffs.count, fileCount)
        let commitKey = try XCTUnwrap(
            HistoricalReviewDiffCacheKey(
                worktreeID: committedSnapshot.id,
                context: .commit(commit.id),
                options: options
            )
        )
        let historicalWriter = ReviewContentStore(directoryURL: cacheDirectory)
        let partialCommitDiffs = Array(commitDiffs.prefix(24))
        try await historicalWriter.savePartialHistoricalDiffs(
            partialCommitDiffs,
            for: commitKey
        )
        let partialCommitReader = ReviewContentStore(
            directoryURL: cacheDirectory
        )
        let restoredPartialCommitDiffs = await partialCommitReader
            .historicalDiffs(for: commitKey)
        XCTAssertEqual(restoredPartialCommitDiffs, partialCommitDiffs)

        try await historicalWriter.saveHistoricalDiffs(
            commitDiffs,
            for: commitKey
        )
        let commitCacheFiles = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let commitAggregateFiles = commitCacheFiles.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("historical-diff-")
                && !name.hasPrefix("historical-diff-file-")
                && !name.hasPrefix("historical-diff-manifest-")
        }
        let commitManifestFiles = commitCacheFiles.filter {
            $0.lastPathComponent.hasPrefix("historical-diff-manifest-")
        }
        let commitSegmentedFiles = commitCacheFiles.filter {
            $0.lastPathComponent.hasPrefix("historical-diff-file-")
        }
        XCTAssertTrue(commitAggregateFiles.isEmpty)
        XCTAssertEqual(commitManifestFiles.count, 1)
        XCTAssertEqual(commitSegmentedFiles.count, fileCount)
        let completeCommitManifestData = try Data(
            contentsOf: try XCTUnwrap(commitManifestFiles.first)
        )
        let completeCommitManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: completeCommitManifestData
            ) as? [String: Any]
        )
        XCTAssertEqual(completeCommitManifest["isComplete"] as? Bool, true)
        let commitReader = ReviewContentStore(directoryURL: cacheDirectory)
        let restoredCommitDiffs = await commitReader.historicalDiffs(
            for: commitKey
        )
        XCTAssertEqual(restoredCommitDiffs, commitDiffs)
        let commitMemoryStats = await commitReader.memoryCacheStats()
        XCTAssertEqual(commitMemoryStats.entryCount, 0)

        let rangeKey = try XCTUnwrap(
            HistoricalReviewDiffCacheKey(
                worktreeID: committedSnapshot.id,
                context: .range(base: parentOID, head: commit.oid),
                options: options
            )
        )
        try await historicalWriter.saveHistoricalDiffs(
            commitDiffs,
            for: rangeKey
        )
        let rangeReader = ReviewContentStore(directoryURL: cacheDirectory)
        let restoredRangeDiffs = await rangeReader.historicalDiffs(for: rangeKey)
        XCTAssertEqual(restoredRangeDiffs, commitDiffs)

        let damagedHistoricalFile = try XCTUnwrap(
            commitSegmentedFiles.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }.first
        )
        try Data("{invalid".utf8).write(to: damagedHistoricalFile)
        let damagedHistoricalReader = ReviewContentStore(
            directoryURL: cacheDirectory
        )
        let damagedHistoricalDiffs = await damagedHistoricalReader
            .historicalDiffs(for: commitKey)
        XCTAssertNil(damagedHistoricalDiffs)
    }

    func testCachesRealRepositoryReviewContentAcrossStoreInstances() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-content-real-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = container.appendingPathComponent("repository", isDirectory: true)
        let cacheDirectory = container.appendingPathComponent("cache", isDirectory: true)
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
        let file = repository.appendingPathComponent("App.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        _ = try await runner.run(
            arguments: ["add", "App.swift"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: repository
        )
        try Data("let value = 2\n".utf8).write(to: file)

        let service = GitRepositoryService()
        let project = try await service.loadProject(at: repository)
        let snapshot = try XCTUnwrap(project.worktrees.first)
        let history = try await service.loadHistoryPage(
            worktree: snapshot.worktree,
            revision: snapshot.worktree.headOID,
            offset: 0,
            pageSize: 200
        )
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: false)
        let workingChanges = snapshot.status.changes.filter(\.isUnstaged)
        let diffs = try await service.loadDiffs(
            worktree: snapshot.worktree,
            changes: workingChanges,
            scope: .working,
            options: options
        )
        let historyKey = HistoryReviewContentCacheKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID,
            pageSize: 200
        )
        let pendingKey = PendingReviewContentCacheKey(snapshot: snapshot, options: options)
        let writer = ReviewContentStore(directoryURL: cacheDirectory)
        try await writer.saveHistoryPage(history, for: historyKey)
        try await writer.savePendingDiffs(diffs, for: pendingKey)

        var wholeFileOptions = options
        wholeFileOptions.context = .wholeFile
        let startupReader = ReviewContentStore(directoryURL: cacheDirectory)
        let startupContent = try XCTUnwrap(
            startupReader.startupContent(
                snapshot: snapshot,
                options: wholeFileOptions
            )
        )
        XCTAssertEqual(startupContent.historyPage, history)
        XCTAssertEqual(startupContent.pendingDiffs, diffs)
        XCTAssertTrue(startupContent.pendingDiffsAreComplete)
        XCTAssertTrue(
            startupContent.matches(
                snapshot: snapshot,
                options: wholeFileOptions
            )
        )

        _ = try await runner.run(
            arguments: ["add", "App.swift"],
            workingDirectory: repository
        )
        _ = try await runner.run(
            arguments: ["commit", "-m", "Update value"],
            workingDirectory: repository
        )
        let committedProject = try await service.loadProject(at: repository)
        let committedSnapshot = try XCTUnwrap(committedProject.worktrees.first)
        let committedHistory = try await service.loadHistoryPage(
            worktree: committedSnapshot.worktree,
            revision: committedSnapshot.worktree.headOID,
            offset: 0,
            pageSize: 200
        )
        let commit = try XCTUnwrap(committedHistory.commits.first)
        let parentOID = try XCTUnwrap(commit.parentOIDs.first)
        let commitMessage = try await service.loadCommitMessage(
            worktree: committedSnapshot.worktree,
            commit: commit
        )
        let commitChanges = try await service.loadCommitChanges(
            worktree: committedSnapshot.worktree,
            commit: commit
        )
        let commitDiffs = try await service.loadCommitDiffs(
            worktree: committedSnapshot.worktree,
            commit: commit,
            changes: commitChanges,
            options: options
        )
        let commitContext = ReviewContext.commit(commit.id)
        let commitDetailsKey = try XCTUnwrap(
            HistoricalReviewDetailsCacheKey(
                worktreeID: committedSnapshot.id,
                context: commitContext
            )
        )
        let commitDiffKey = try XCTUnwrap(
            HistoricalReviewDiffCacheKey(
                worktreeID: committedSnapshot.id,
                context: commitContext,
                options: options
            )
        )
        let commitDetails = HistoricalReviewDetails(
            message: commitMessage,
            changes: commitChanges
        )
        try await writer.saveHistoricalDetails(commitDetails, for: commitDetailsKey)
        try await writer.saveHistoricalDiffs(commitDiffs, for: commitDiffKey)

        let rangeContext = ReviewContext.range(base: parentOID, head: commit.oid)
        let rangeChanges = try await service.loadRangeChanges(
            worktree: committedSnapshot.worktree,
            baseOID: parentOID,
            headOID: commit.oid
        )
        let rangeDiffs = try await service.loadRangeDiffs(
            worktree: committedSnapshot.worktree,
            baseOID: parentOID,
            headOID: commit.oid,
            changes: rangeChanges,
            options: options
        )
        let rangeDetailsKey = try XCTUnwrap(
            HistoricalReviewDetailsCacheKey(
                worktreeID: committedSnapshot.id,
                context: rangeContext
            )
        )
        let rangeDiffKey = try XCTUnwrap(
            HistoricalReviewDiffCacheKey(
                worktreeID: committedSnapshot.id,
                context: rangeContext,
                options: options
            )
        )
        let rangeDetails = HistoricalReviewDetails(message: "", changes: rangeChanges)
        try await writer.saveHistoricalDetails(rangeDetails, for: rangeDetailsKey)
        try await writer.saveHistoricalDiffs(rangeDiffs, for: rangeDiffKey)

        let reader = ReviewContentStore(directoryURL: cacheDirectory)
        let restoredHistory = await reader.historyPage(for: historyKey)
        let restoredDiffs = await reader.pendingDiffs(for: pendingKey)
        let restoredCommitDetails = await reader.historicalDetails(for: commitDetailsKey)
        let restoredCommitDiffs = await reader.historicalDiffs(for: commitDiffKey)
        let restoredRangeDetails = await reader.historicalDetails(for: rangeDetailsKey)
        let restoredRangeDiffs = await reader.historicalDiffs(for: rangeDiffKey)
        XCTAssertEqual(restoredHistory, history)
        XCTAssertEqual(restoredDiffs, diffs)
        XCTAssertEqual(restoredCommitDetails, commitDetails)
        XCTAssertEqual(restoredCommitDiffs, commitDiffs)
        XCTAssertEqual(restoredRangeDetails, rangeDetails)
        XCTAssertEqual(restoredRangeDiffs, rangeDiffs)
    }

    func testRoundTripsHistoryAndPendingDiffsWithExactInvalidation() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-content-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewContentStore(directoryURL: directory)
        let historyKey = HistoryReviewContentCacheKey(
            worktreeID: "/worktrees/feature",
            revision: String(repeating: "a", count: 40),
            pageSize: 200
        )
        let page = GitHistoryPage(
            commits: [
                GitCommit(
                    oid: String(repeating: "a", count: 40),
                    shortOID: "aaaaaaa",
                    authorName: "AgentGit Tests",
                    authoredAt: Date(timeIntervalSince1970: 100),
                    parentOIDs: [],
                    refNames: ["HEAD -> refs/heads/feature"],
                    subject: "Cached commit"
                )
            ],
            nextOffset: 1,
            hasMore: false
        )
        try await store.saveHistoryPage(page, for: historyKey)

        let restoredHistory = await store.historyPage(for: historyKey)
        let otherRevisionHistory = await store.historyPage(
            for: HistoryReviewContentCacheKey(
                worktreeID: historyKey.worktreeID,
                revision: String(repeating: "b", count: 40),
                pageSize: historyKey.pageSize
            )
        )
        XCTAssertEqual(restoredHistory, page)
        XCTAssertNil(otherRevisionHistory)

        let snapshot = makeSnapshot(activityAt: Date(timeIntervalSince1970: 200))
        let options = GitDiffOptions(context: .lines(3), ignoresWhitespace: true)
        let pendingKey = PendingReviewContentCacheKey(snapshot: snapshot, options: options)
        let diff = makeDiff(change: try XCTUnwrap(snapshot.status.changes.first))
        try await store.savePendingDiffs([diff], for: pendingKey)

        let restoredDiffs = await store.pendingDiffs(for: pendingKey)
        let changedSnapshotDiffs = await store.pendingDiffs(
            for: PendingReviewContentCacheKey(
                snapshot: makeSnapshot(activityAt: Date(timeIntervalSince1970: 201)),
                options: options
            )
        )
        XCTAssertEqual(restoredDiffs, [diff])
        XCTAssertNil(changedSnapshotDiffs)

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 2)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testMergesSupplementalDiffEntriesForPendingAndHistoricalReview() async throws {
        let directory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/review-content-supplemental-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewContentStore(directoryURL: directory)
        let snapshot = makeSnapshot(activityAt: Date(timeIntervalSince1970: 300))
        let firstChange = try XCTUnwrap(snapshot.status.changes.first)
        let secondChange = GitFileChange(
            path: "Sources/Second.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        let firstDiff = makeDiff(change: firstChange)
        let secondDiff = makeDiff(change: secondChange)
        let options = GitDiffOptions(context: .wholeFile, ignoresWhitespace: false)
        let pendingKey = PendingReviewContentCacheKey(
            snapshot: snapshot,
            options: options
        )

        try await store.savePendingDiff(firstDiff, for: pendingKey)
        try await store.savePendingDiff(secondDiff, for: pendingKey)

        let cachedFirstPendingDiff = await store.pendingDiff(
            changeID: firstChange.id,
            scope: .working,
            for: pendingKey
        )
        let cachedSecondPendingDiff = await store.pendingDiff(
            changeID: secondChange.id,
            scope: .working,
            for: pendingKey
        )
        XCTAssertEqual(cachedFirstPendingDiff, firstDiff)
        XCTAssertEqual(cachedSecondPendingDiff, secondDiff)

        let historicalKey = try XCTUnwrap(
            HistoricalReviewDiffCacheKey(
                worktreeID: snapshot.id,
                context: .commit(String(repeating: "c", count: 40)),
                options: options
            )
        )
        try await store.saveHistoricalDiff(firstDiff, for: historicalKey)
        try await store.saveHistoricalDiff(secondDiff, for: historicalKey)

        let cachedFirstHistoricalDiff = await store.historicalDiff(
            changeID: firstChange.id,
            for: historicalKey
        )
        let cachedSecondHistoricalDiff = await store.historicalDiff(
            changeID: secondChange.id,
            for: historicalKey
        )
        XCTAssertEqual(cachedFirstHistoricalDiff, firstDiff)
        XCTAssertEqual(cachedSecondHistoricalDiff, secondDiff)
    }

    private func makeSnapshot(activityAt: Date) -> GitWorktreeSnapshot {
        let worktree = GitWorktree(
            rootURL: URL(fileURLWithPath: "/worktrees/feature"),
            headOID: String(repeating: "a", count: 40),
            branchRef: "refs/heads/feature",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let change = GitFileChange(
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        return GitWorktreeSnapshot(
            worktree: worktree,
            status: GitStatusSnapshot(
                changes: [change],
                branch: GitBranchStatus(
                    upstreamRef: "origin/feature",
                    aheadCount: 0,
                    behindCount: 0
                ),
                headOID: worktree.headOID,
                branchHead: "feature"
            ),
            diffStat: GitDiffStat(addedLineCount: 1, deletedLineCount: 1),
            lastActivityAt: activityAt,
            errorMessage: nil
        )
    }

    private func makeHistoryPage(
        oidCharacter: Character,
        subject: String
    ) -> GitHistoryPage {
        let oid = String(repeating: String(oidCharacter), count: 40)
        return GitHistoryPage(
            commits: [
                GitCommit(
                    oid: oid,
                    shortOID: String(oid.prefix(7)),
                    authorName: "AgentGit Tests",
                    authoredAt: Date(timeIntervalSince1970: 100),
                    parentOIDs: [],
                    refNames: [],
                    subject: subject
                )
            ],
            nextOffset: 1,
            hasMore: false
        )
    }

    private func makeDiff(
        change: GitFileChange,
        scope: GitDiffScope = .working
    ) -> GitFileDiff {
        GitFileDiff(
            change: change,
            scope: scope,
            hunks: [
                GitDiffHunk(
                    id: 0,
                    header: "@@ -1 +1 @@",
                    sectionHeading: "cachedValue",
                    oldStart: 1,
                    oldCount: 1,
                    newStart: 1,
                    newCount: 1,
                    lines: [
                        GitDiffLine(
                            id: 0,
                            kind: .deletion,
                            oldLineNumber: 1,
                            newLineNumber: nil,
                            content: "let value = 1",
                            inlineRanges: [GitDiffInlineRange(location: 12, length: 1)]
                        ),
                        GitDiffLine(
                            id: 1,
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: 1,
                            content: "let value = 2",
                            inlineRanges: [GitDiffInlineRange(location: 12, length: 1)]
                        )
                    ]
                )
            ],
            state: .textual
        )
    }
}
