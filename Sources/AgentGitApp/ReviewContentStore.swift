import AgentGitCore
import CryptoKit
import Foundation

struct HistoryReviewContentCacheKey: Codable, Hashable, Sendable {
    let worktreeID: GitWorktree.ID
    let revision: String?
    let pageSize: Int
}

struct PendingReviewContentCacheKey: Codable, Hashable, Sendable {
    let worktreeID: GitWorktree.ID
    let headOID: String?
    let status: GitStatusSnapshot
    let diffStat: GitDiffStat
    let lastActivityAt: Date
    let options: GitDiffOptions

    init(snapshot: GitWorktreeSnapshot, options: GitDiffOptions) {
        worktreeID = snapshot.id
        headOID = snapshot.worktree.headOID
        status = snapshot.status
        diffStat = snapshot.diffStat
        let milliseconds = floor(snapshot.lastActivityAt.timeIntervalSince1970 * 1_000)
        lastActivityAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        self.options = options
    }
}

struct HistoricalReviewDetailsCacheKey: Codable, Hashable, Sendable {
    let worktreeID: GitWorktree.ID
    let context: ReviewContext

    init?(worktreeID: GitWorktree.ID, context: ReviewContext) {
        guard context != .pending else {
            return nil
        }
        self.worktreeID = worktreeID
        self.context = context
    }
}

struct HistoricalReviewDiffCacheKey: Codable, Hashable, Sendable {
    let worktreeID: GitWorktree.ID
    let context: ReviewContext
    let options: GitDiffOptions

    init?(
        worktreeID: GitWorktree.ID,
        context: ReviewContext,
        options: GitDiffOptions
    ) {
        guard context != .pending else {
            return nil
        }
        self.worktreeID = worktreeID
        self.context = context
        self.options = options
    }
}

struct HistoricalReviewDetails: Codable, Equatable, Sendable {
    let message: String
    let changes: [GitFileChange]
    let commitMetadata: GitCommitMetadata?

    init(
        message: String,
        changes: [GitFileChange],
        commitMetadata: GitCommitMetadata? = nil
    ) {
        self.message = message
        self.changes = changes
        self.commitMetadata = commitMetadata
    }
}

struct StartupReviewContent: Sendable {
    static let historyPageSize = 100
    static let legacyHistoryPageSizes = [200]

    let pendingKey: PendingReviewContentCacheKey
    let historyKey: HistoryReviewContentCacheKey
    let pendingDiffs: [GitFileDiff]?
    let pendingDiffsAreComplete: Bool
    let historyPage: GitHistoryPage?
    let historicalContext: ReviewContext?
    let historicalDetails: HistoricalReviewDetails?
    let historicalDiffs: [GitFileDiff]?
    let historicalDiffsAreComplete: Bool

    var isEmpty: Bool {
        pendingDiffs == nil
            && historyPage == nil
            && historicalDetails == nil
            && historicalDiffs == nil
    }

    func matches(
        snapshot: GitWorktreeSnapshot,
        options: GitDiffOptions
    ) -> Bool {
        pendingKey == PendingReviewContentCacheKey(
            snapshot: snapshot,
            options: Self.compactOptions(options)
        ) && historyKey == HistoryReviewContentCacheKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID,
            pageSize: Self.historyPageSize
        )
    }

    /// 与 Review 加载一致：忽略空白只在显示时处理，缓存里存的是完整 diff。
    static func compactOptions(_ options: GitDiffOptions) -> GitDiffOptions {
        var compact = options
        compact.ignoresWhitespace = false
        if compact.context == .wholeFile {
            compact.context = .lines(3)
        }
        return compact
    }
}

struct ReviewDiffCacheEntry: Equatable, Sendable {
    let diffs: [GitFileDiff]
    let isComplete: Bool
    let sourceIdentities: [GitPendingDiffIdentity]
    let serializedByteCount: Int

    init(
        diffs: [GitFileDiff], isComplete: Bool,
        sourceIdentities: [GitPendingDiffIdentity] = [], serializedByteCount: Int = 0
    ) {
        self.diffs = diffs
        self.isComplete = isComplete
        self.sourceIdentities = sourceIdentities
        self.serializedByteCount = serializedByteCount
    }
}

private enum ReviewMemoryCacheKey: Hashable {
    case history(HistoryReviewContentCacheKey)
    case pending(PendingReviewContentCacheKey)
    case pendingFile(GitPendingDiffIdentity)
    case historicalDetails(HistoricalReviewDetailsCacheKey)
    case historicalDiff(HistoricalReviewDiffCacheKey)
}

private struct ReviewMemoryCacheMetadata {
    let serializedByteCount: Int
    let accessSequence: UInt64
}

private struct PendingReviewFileCacheKey: Codable, Hashable, Sendable {
    let pendingKeyDigest: String
    let changeID: GitFileChange.ID
    let scope: GitDiffScope
}

private struct PendingReviewFileDescriptor: Codable, Hashable, Sendable {
    let changeID: GitFileChange.ID
    let scope: GitDiffScope
    let serializedByteCount: Int

    func cacheKey(
        pendingKeyDigest: String
    ) -> PendingReviewFileCacheKey {
        PendingReviewFileCacheKey(
            pendingKeyDigest: pendingKeyDigest,
            changeID: changeID,
            scope: scope
        )
    }
}

private struct StartupPendingReviewContent {
    let diffs: [GitFileDiff]
    let isComplete: Bool
}

private struct StartupHistoricalReviewContent {
    let diffs: [GitFileDiff]
    let isComplete: Bool
}

private struct LoadedPendingReviewSegments {
    let diffs: [GitFileDiff]
    let serializedByteCount: Int
    let isComplete: Bool
}

private struct HistoricalReviewFileCacheKey: Codable, Hashable, Sendable {
    let historicalKeyDigest: String
    let changeID: GitFileChange.ID
    let scope: GitDiffScope
}

private struct HistoricalReviewFileDescriptor: Codable, Hashable, Sendable {
    let changeID: GitFileChange.ID
    let scope: GitDiffScope
    let serializedByteCount: Int

    func cacheKey(
        historicalKeyDigest: String
    ) -> HistoricalReviewFileCacheKey {
        HistoricalReviewFileCacheKey(
            historicalKeyDigest: historicalKeyDigest,
            changeID: changeID,
            scope: scope
        )
    }
}

private struct LoadedHistoricalReviewSegments {
    let diffs: [GitFileDiff]
    let serializedByteCount: Int
    let isComplete: Bool
}

actor ReviewContentStore {
    private static let schemaVersion = 1
    private static let maximumEntryByteCount = 32 * 1_024 * 1_024
    private static let maximumStartupEntryByteCount = 8 * 1_024 * 1_024
    private static let maximumCacheByteCount = 128 * 1_024 * 1_024
    private static let cachePruningTargetByteCount = 112 * 1_024 * 1_024
    private static let maximumIndexedCacheFileCount = 16_384
    private static let cacheFileTouchInterval: TimeInterval = 15
    private static let defaultMaximumMemoryCacheByteCount = 16 * 1_024 * 1_024
    private static let defaultMaximumMemoryCacheEntryCount = 24

    nonisolated let directoryURL: URL
    private let maximumMemoryCacheByteCount: Int
    private let maximumMemoryCacheEntryCount: Int

    private var historyPages: [HistoryReviewContentCacheKey: GitHistoryPage] = [:]
    private var pendingDiffsByKey: [PendingReviewContentCacheKey: [GitFileDiff]] = [:]
    private var pendingDiffCompletenessByKey: [PendingReviewContentCacheKey: Bool] = [:]
    private var reusablePendingDiffs: [GitPendingDiffIdentity: GitFileDiff] = [:]
    /// 同一份内容见过哪些上下文行数，键是把上下文清零后的身份。
    private var pendingContextsByContent: [GitPendingDiffIdentity: Set<GitDiffContext>] = [:]
    private var knownCacheByteCount: Int?
    private var cacheFilesByURL: [URL: CacheFile]?
    private var cacheDirectoryModifiedAt: Date?
    private var lastCacheDirectoryScan = Date.distantPast
    private var historicalDetailsByKey: [
        HistoricalReviewDetailsCacheKey: HistoricalReviewDetails
    ] = [:]
    private var historicalDiffsByKey: [
        HistoricalReviewDiffCacheKey: [GitFileDiff]
    ] = [:]
    private var historicalDiffCompletenessByKey: [
        HistoricalReviewDiffCacheKey: Bool
    ] = [:]
    private var memoryCacheMetadata: [
        ReviewMemoryCacheKey: ReviewMemoryCacheMetadata
    ] = [:]
    private var memoryCacheByteCount = 0
    private var memoryCacheAccessSequence: UInt64 = 0

    init(
        directoryURL: URL,
        maximumMemoryCacheByteCount: Int = ReviewContentStore
            .defaultMaximumMemoryCacheByteCount,
        maximumMemoryCacheEntryCount: Int = ReviewContentStore
            .defaultMaximumMemoryCacheEntryCount
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.maximumMemoryCacheByteCount = max(0, maximumMemoryCacheByteCount)
        self.maximumMemoryCacheEntryCount = max(0, maximumMemoryCacheEntryCount)
    }

    nonisolated static var defaultDirectoryURL: URL {
        let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return cacheRoot
            .appendingPathComponent("com.sigma.agentgit", isDirectory: true)
            .appendingPathComponent("review-content-v1", isDirectory: true)
    }

    nonisolated func startupContent(
        snapshot: GitWorktreeSnapshot,
        options: GitDiffOptions,
        historicalContext: ReviewContext? = nil
    ) -> StartupReviewContent? {
        let historicalContext = historicalContext == .pending
            ? nil
            : historicalContext
        let pendingKey = PendingReviewContentCacheKey(
            snapshot: snapshot,
            options: StartupReviewContent.compactOptions(options)
        )
        let historyKey = HistoryReviewContentCacheKey(
            worktreeID: snapshot.id,
            revision: snapshot.worktree.headOID,
            pageSize: StartupReviewContent.historyPageSize
        )
        let pendingEntry: PersistedPendingReviewContent? = historicalContext == nil
            ? Self.loadEntry(
                at: Self.cacheFileURL(
                    directoryURL: directoryURL,
                    prefix: "pending",
                    key: pendingKey
                ),
                maximumByteCount: Self.maximumStartupEntryByteCount
            )
            : nil
        let historyEntry: PersistedHistoryReviewContent? = Self.loadEntry(
            at: Self.cacheFileURL(
                directoryURL: directoryURL,
                prefix: "history",
                key: historyKey
            ),
            maximumByteCount: Self.maximumStartupEntryByteCount
        )
        let aggregatePendingDiffs = pendingEntry.flatMap {
            $0.version == Self.schemaVersion && $0.key == pendingKey
                ? $0.diffs
                : nil
        }
        let segmentedPendingContent = aggregatePendingDiffs == nil
            ? Self.loadStartupPendingSegments(
                directoryURL: directoryURL,
                key: pendingKey,
                maximumByteCount: Self.maximumStartupEntryByteCount
            )
            : nil
        let pendingDiffs = aggregatePendingDiffs
            ?? segmentedPendingContent?.diffs
        let historyPage = historyEntry.flatMap {
            $0.version == Self.schemaVersion && $0.key == historyKey
                ? $0.page
                : nil
        } ?? Self.migratedLegacyHistoryPage(
            directoryURL: directoryURL,
            key: historyKey,
            maximumByteCount: Self.maximumStartupEntryByteCount
        )
        let historicalDetailsKey = historicalContext.flatMap {
            HistoricalReviewDetailsCacheKey(
                worktreeID: snapshot.id,
                context: $0
            )
        }
        let historicalDiffKey = historicalContext.flatMap {
            HistoricalReviewDiffCacheKey(
                worktreeID: snapshot.id,
                context: $0,
                options: StartupReviewContent.compactOptions(options)
            )
        }
        let historicalDetailsEntry: PersistedHistoricalReviewDetails? =
            historicalDetailsKey.flatMap { key in
                Self.loadEntry(
                    at: Self.cacheFileURL(
                        directoryURL: directoryURL,
                        prefix: "historical-details",
                        key: key
                    ),
                    maximumByteCount: Self.maximumStartupEntryByteCount
                )
            }
        let historicalDetails = historicalDetailsEntry.flatMap { entry in
            historicalDetailsKey == entry.key && entry.version == Self.schemaVersion
                ? entry.details
                : nil
        }
        let historicalDiffEntry: PersistedHistoricalReviewDiff? =
            historicalDiffKey.flatMap { key in
                Self.loadEntry(
                    at: Self.cacheFileURL(
                        directoryURL: directoryURL,
                        prefix: "historical-diff",
                        key: key
                    ),
                    maximumByteCount: Self.maximumStartupEntryByteCount
                )
            }
        let aggregateHistoricalDiffs = historicalDiffEntry.flatMap { entry in
            historicalDiffKey == entry.key && entry.version == Self.schemaVersion
                ? entry.diffs
                : nil
        }
        let segmentedHistoricalContent = aggregateHistoricalDiffs == nil
            ? historicalDiffKey.flatMap { key in
                Self.loadStartupHistoricalSegments(
                    directoryURL: directoryURL,
                    key: key,
                    maximumByteCount: Self.maximumStartupEntryByteCount
                )
            }
            : nil
        let historicalDiffs = aggregateHistoricalDiffs
            ?? segmentedHistoricalContent?.diffs
        let content = StartupReviewContent(
            pendingKey: pendingKey,
            historyKey: historyKey,
            pendingDiffs: pendingDiffs,
            pendingDiffsAreComplete: aggregatePendingDiffs != nil
                || segmentedPendingContent?.isComplete == true,
            historyPage: historyPage,
            historicalContext: historicalContext,
            historicalDetails: historicalDetails,
            historicalDiffs: historicalDiffs,
            historicalDiffsAreComplete: aggregateHistoricalDiffs != nil
                || segmentedHistoricalContent?.isComplete == true
        )
        return content.isEmpty ? nil : content
    }

    func historyPage(
        for key: HistoryReviewContentCacheKey
    ) -> GitHistoryPage? {
        if let page = historyPages[key] {
            touchMemoryCache(.history(key))
            return page
        }
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "history",
            key: key
        )
        guard let entry: PersistedHistoryReviewContent = Self.loadEntry(at: fileURL),
              entry.version == Self.schemaVersion,
              entry.key == key else {
            removeInvalidCacheFile(at: fileURL)
            guard let migrated = Self.migratedLegacyHistoryPage(
                directoryURL: directoryURL,
                key: key,
                maximumByteCount: Self.maximumEntryByteCount
            ) else {
                return nil
            }
            try? saveHistoryPage(migrated, for: key)
            return migrated
        }
        historyPages[key] = entry.page
        rememberMemoryCache(
            .history(key),
            serializedByteCount: Self.cacheFileByteCount(at: fileURL)
        )
        touchCacheFile(at: fileURL)
        return entry.page
    }

    private nonisolated static func migratedLegacyHistoryPage(
        directoryURL: URL,
        key: HistoryReviewContentCacheKey,
        maximumByteCount: Int
    ) -> GitHistoryPage? {
        guard key.pageSize == StartupReviewContent.historyPageSize else {
            return nil
        }
        for legacyPageSize in StartupReviewContent.legacyHistoryPageSizes {
            let legacyKey = HistoryReviewContentCacheKey(
                worktreeID: key.worktreeID,
                revision: key.revision,
                pageSize: legacyPageSize
            )
            let legacyURL = cacheFileURL(
                directoryURL: directoryURL,
                prefix: "history",
                key: legacyKey
            )
            guard let entry: PersistedHistoryReviewContent = loadEntry(
                at: legacyURL,
                maximumByteCount: maximumByteCount
            ), entry.version == schemaVersion,
               entry.key == legacyKey else {
                continue
            }
            let retainedCommits = Array(entry.page.commits.prefix(key.pageSize))
            return GitHistoryPage(
                commits: retainedCommits,
                nextOffset: retainedCommits.count,
                hasMore: entry.page.hasMore
                    || retainedCommits.count < entry.page.commits.count
            )
        }
        return nil
    }

    func saveHistoryPage(
        _ page: GitHistoryPage,
        for key: HistoryReviewContentCacheKey
    ) throws {
        let entry = PersistedHistoryReviewContent(
            version: Self.schemaVersion,
            key: key,
            page: page
        )
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "history",
            key: key
        )
        if let byteCount = try save(
            entry,
            to: fileURL
        ) {
            historyPages[key] = page
            rememberMemoryCache(.history(key), serializedByteCount: byteCount)
        } else {
            removeMemoryCacheValue(for: .history(key))
        }
    }

    func reusablePendingDiffEntry(
        for key: PendingReviewContentCacheKey,
        identities: [GitPendingDiffIdentity]
    ) -> ReviewDiffCacheEntry {
        let aggregate = pendingDiffEntry(for: key)
        let aggregateByIdentity = Dictionary(
            (aggregate?.diffs ?? []).compactMap { diff in
                diff.sourceIdentity.map { ($0, diff) }
            }, uniquingKeysWith: { first, _ in first }
        )
        var diffs: [GitFileDiff] = []
        var remainingBytes = max(0, Self.maximumCacheByteCount - (aggregate?.serializedByteCount ?? 0))
        let changes = Dictionary(key.status.changes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for identity in identities {
            guard let change = changes[identity.changeID] else { continue }
            if let diff = aggregateByIdentity[identity] {
                diffs.append(diff.withChange(change))
                continue
            }
            guard let cached = reusablePendingDiff(for: identity, maximumByteCount: remainingBytes) else { continue }
            remainingBytes -= cached.byteCount
            diffs.append(cached.diff.withChange(change))
        }
        let expectedCount = key.status.changes.reduce(0) { count, change in
            count + (change.isStaged ? 1 : 0) + (change.isUnstaged || change.isUntracked ? 1 : 0)
        }
        return ReviewDiffCacheEntry(
            diffs: diffs, isComplete: diffs.count == expectedCount
                && aggregate?.isComplete == true && aggregateByIdentity.count == expectedCount,
            sourceIdentities: identities
        )
    }

    func reusablePendingDiff(
        for identity: GitPendingDiffIdentity,
        maximumByteCount: Int = ReviewContentStore.maximumEntryByteCount
    ) -> (diff: GitFileDiff, byteCount: Int)? {
        storedReusablePendingDiff(for: identity, maximumByteCount: maximumByteCount)
            ?? trimmedReusablePendingDiff(for: identity, maximumByteCount: maximumByteCount)
    }

    /// 上下文行数变少时，从同一份内容上下文更多的结果裁出来，不再跑 Git。
    /// hunk 标题要按 Git 默认规则重算，指定了 diff 驱动的文件不裁。
    private func trimmedReusablePendingDiff(
        for identity: GitPendingDiffIdentity,
        maximumByteCount: Int
    ) -> (diff: GitFileDiff, byteCount: Int)? {
        guard identity.usesDefaultFunctionNames, case .lines = identity.context else { return nil }
        let known = pendingContextsByContent[identity.withContext(.lines(0))] ?? []
        let candidates = known.union([.wholeFile, .lines(25), .lines(8)])
            .filter { Self.context($0, covers: identity.context) }
            .sorted { Self.context($1, covers: $0) }
        for context in candidates {
            guard let source = storedReusablePendingDiff(
                for: identity.withContext(context), maximumByteCount: maximumByteCount
            ) else { continue }
            // 超过行数上限的结果和上下文有关，换成更少的上下文可能就不超了。
            switch source.diff.state {
            case .textual, .binary, .metadata: break
            case .tooLarge, .unavailable: continue
            }
            let diff = GitDiffContextTrimmer.trimming(
                source.diff, to: identity.context, recomputesSectionHeadings: true
            ).withSourceIdentity(identity)
            reusablePendingDiffs[identity] = diff
            rememberMemoryCache(.pendingFile(identity), serializedByteCount: source.byteCount)
            notePendingContext(of: identity)
            return (diff, source.byteCount)
        }
        return nil
    }

    private nonisolated static func context(_ context: GitDiffContext, covers target: GitDiffContext) -> Bool {
        switch (context, target) {
        case (.wholeFile, .lines): true
        case let (.lines(count), .lines(targetCount)): count > targetCount
        default: false
        }
    }

    private func notePendingContext(of identity: GitPendingDiffIdentity) {
        let key = identity.withContext(.lines(0))
        if pendingContextsByContent.count >= 16_384, pendingContextsByContent[key] == nil {
            pendingContextsByContent.removeAll(keepingCapacity: true)
        }
        pendingContextsByContent[key, default: []].insert(identity.context)
    }

    private func storedReusablePendingDiff(
        for identity: GitPendingDiffIdentity,
        maximumByteCount: Int
    ) -> (diff: GitFileDiff, byteCount: Int)? {
        if let diff = reusablePendingDiffs[identity],
           let metadata = memoryCacheMetadata[.pendingFile(identity)],
           metadata.serializedByteCount <= maximumByteCount {
            touchMemoryCache(.pendingFile(identity))
            return (diff, metadata.serializedByteCount)
        }
        let fileURL = Self.reusablePendingFileURL(directoryURL: directoryURL, identity: identity)
        let byteCount = Self.cacheFileByteCount(at: fileURL)
        guard byteCount <= maximumByteCount,
              let entry: PersistedReusablePendingFile = Self.loadEntry(
                at: fileURL, maximumByteCount: min(maximumByteCount, Self.maximumEntryByteCount)
              ), entry.version == Self.schemaVersion, entry.identity == identity,
              entry.diff.sourceIdentity == identity else { return nil }
        reusablePendingDiffs[identity] = entry.diff
        rememberMemoryCache(.pendingFile(identity), serializedByteCount: byteCount)
        notePendingContext(of: identity)
        touchCacheFile(at: fileURL)
        return (entry.diff, byteCount)
    }

    func saveReusablePendingDiffs(_ diffs: [GitFileDiff]) throws {
        for diff in diffs {
            guard let identity = diff.sourceIdentity else { continue }
            let fileURL = Self.reusablePendingFileURL(directoryURL: directoryURL, identity: identity)
            if storedReusablePendingDiff(
                for: identity, maximumByteCount: Self.maximumEntryByteCount
            )?.diff == diff,
               FileManager.default.fileExists(atPath: fileURL.path) {
                touchMemoryCache(.pendingFile(identity))
                touchCacheFile(at: fileURL)
                continue
            }
            let entry = PersistedReusablePendingFile(version: Self.schemaVersion, identity: identity, diff: diff)
            guard let byteCount = try save(entry, to: fileURL, prunesCache: false) else { continue }
            reusablePendingDiffs[identity] = diff
            rememberMemoryCache(.pendingFile(identity), serializedByteCount: byteCount)
            notePendingContext(of: identity)
        }
        try pruneIfNeeded()
    }

    private nonisolated static func reusablePendingFileURL(
        directoryURL: URL, identity: GitPendingDiffIdentity
    ) -> URL {
        let data = (try? makeEncoder().encode(identity)) ?? Data()
        let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("pending-content-\(digest).json")
    }

    func pendingDiffEntry(
        for key: PendingReviewContentCacheKey
    ) -> ReviewDiffCacheEntry? {
        if let diffs = pendingDiffsByKey[key] {
            touchMemoryCache(.pending(key))
            return ReviewDiffCacheEntry(
                diffs: diffs,
                isComplete: pendingDiffCompletenessByKey[key] ?? true,
                serializedByteCount: memoryCacheMetadata[.pending(key)]?.serializedByteCount ?? 0
            )
        }
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "pending",
            key: key
        )
        if let entry: PersistedPendingReviewContent = Self.loadEntry(at: fileURL),
           entry.version == Self.schemaVersion,
           entry.key == key {
            let byteCount = Self.cacheFileByteCount(at: fileURL)
            pendingDiffsByKey[key] = entry.diffs
            pendingDiffCompletenessByKey[key] = true
            rememberMemoryCache(
                .pending(key),
                serializedByteCount: byteCount
            )
            touchCacheFile(at: fileURL)
            return ReviewDiffCacheEntry(
                diffs: entry.diffs,
                isComplete: true,
                serializedByteCount: byteCount
            )
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            removeInvalidCacheFile(at: fileURL)
        }
        guard let segmented = loadPendingSegments(for: key) else {
            return nil
        }
        pendingDiffsByKey[key] = segmented.diffs
        pendingDiffCompletenessByKey[key] = segmented.isComplete
        rememberMemoryCache(
            .pending(key),
            serializedByteCount: segmented.serializedByteCount
        )
        return ReviewDiffCacheEntry(
            diffs: segmented.diffs,
            isComplete: segmented.isComplete,
            serializedByteCount: segmented.serializedByteCount
        )
    }

    func savePendingDiffs(
        _ diffs: [GitFileDiff],
        for key: PendingReviewContentCacheKey
    ) throws {
        let sortedDiffs = diffs.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return lhs.scope.rawValue < rhs.scope.rawValue
            }
            return lhs.change.id < rhs.change.id
        }
        let entry = PersistedPendingReviewContent(
            version: Self.schemaVersion,
            key: key,
            diffs: sortedDiffs
        )
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "pending",
            key: key
        )
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL, prefix: "pending-manifest", key: key
        )
        let manifest: PersistedPendingReviewManifest? = Self.loadEntry(at: manifestURL)
        let hasSegments = manifest?.version == Self.schemaVersion && manifest?.key == key
        // 已有分段继续增量更新；整份缓存只保留启动时可以直接读取的小条目。
        let aggregateByteCount = hasSegments ? nil : try save(
            entry,
            to: fileURL,
            prunesCache: false,
            maximumByteCount: Self.maximumStartupEntryByteCount
        )
        let segmentedByteCount: Int?
        if aggregateByteCount == nil {
            try removeCacheFileIfPresent(at: fileURL)
            segmentedByteCount = try savePendingSegments(
                sortedDiffs,
                for: key,
                isComplete: true
            )
        } else {
            removePendingSegments(for: key)
            segmentedByteCount = nil
        }
        try pruneIfNeeded()
        if let serializedByteCount = aggregateByteCount ?? segmentedByteCount {
            pendingDiffsByKey[key] = sortedDiffs
            pendingDiffCompletenessByKey[key] = true
            rememberMemoryCache(
                .pending(key),
                serializedByteCount: serializedByteCount
            )
        } else {
            removeMemoryCacheValue(for: .pending(key))
        }
    }

    func savePartialPendingDiffs(
        _ diffs: [GitFileDiff],
        for key: PendingReviewContentCacheKey
    ) throws {
        let sortedDiffs = diffs.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return lhs.scope.rawValue < rhs.scope.rawValue
            }
            return lhs.change.id < rhs.change.id
        }
        let aggregateURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "pending",
            key: key
        )
        try removeCacheFileIfPresent(at: aggregateURL)
        let serializedByteCount = try savePendingSegments(
            sortedDiffs,
            for: key,
            isComplete: false
        )
        try pruneIfNeeded()
        if let serializedByteCount {
            pendingDiffsByKey[key] = sortedDiffs
            pendingDiffCompletenessByKey[key] = false
            rememberMemoryCache(
                .pending(key),
                serializedByteCount: serializedByteCount
            )
        } else {
            removeMemoryCacheValue(for: .pending(key))
        }
    }

    func savePendingDiff(
        _ diff: GitFileDiff,
        for key: PendingReviewContentCacheKey
    ) throws {
        let existing = pendingDiffEntry(for: key)
        var diffs = existing?.diffs ?? []
        diffs.removeAll {
            $0.change.id == diff.change.id && $0.scope == diff.scope
        }
        diffs.append(diff)
        let sortedDiffs = diffs.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return lhs.scope.rawValue < rhs.scope.rawValue
            }
            return lhs.change.id < rhs.change.id
        }
        let isComplete = existing?.isComplete == true
        let aggregateURL = Self.cacheFileURL(directoryURL: directoryURL, prefix: "pending", key: key)
        try removeCacheFileIfPresent(at: aggregateURL)
        let serializedByteCount = try savePendingSegments(sortedDiffs, for: key, isComplete: isComplete)
        try pruneIfNeeded()
        if let serializedByteCount {
            pendingDiffsByKey[key] = sortedDiffs
            pendingDiffCompletenessByKey[key] = isComplete
            rememberMemoryCache(.pending(key), serializedByteCount: serializedByteCount)
        } else {
            removeMemoryCacheValue(for: .pending(key))
        }
    }

    private func savePendingSegments(
        _ diffs: [GitFileDiff],
        for key: PendingReviewContentCacheKey,
        isComplete: Bool
    ) throws -> Int? {
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "pending-manifest",
            key: key
        )
        let previousManifest: PersistedPendingReviewManifest? = Self.loadEntry(
            at: manifestURL
        )
        let pendingKeyDigest = Self.cacheKeyDigest(key)
        let previousDescriptors: [PendingReviewFileDescriptor] = if
            previousManifest?.version == Self.schemaVersion,
            previousManifest?.key == key {
            previousManifest?.files ?? []
        } else {
            []
        }
        let reusableDescriptors: [
            PendingReviewFileCacheKey: PendingReviewFileDescriptor
        ] = Dictionary(
            previousDescriptors.map {
                ($0.cacheKey(pendingKeyDigest: pendingKeyDigest), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var descriptors: [PendingReviewFileDescriptor] = []
        var writtenURLs: [URL] = []
        var invalidatedPreviousManifest = false
        var completed = false
        defer {
            if !completed {
                for fileURL in writtenURLs {
                    try? removeCacheFile(at: fileURL)
                }
            }
        }

        for diff in diffs {
            let fileKey = PendingReviewFileCacheKey(
                pendingKeyDigest: pendingKeyDigest,
                changeID: diff.change.id,
                scope: diff.scope
            )
            let fileURL = Self.cacheFileURL(
                directoryURL: directoryURL,
                prefix: "pending-file",
                key: fileKey
            )
            if let reusable = reusableDescriptors[fileKey],
               Self.cacheFileByteCount(at: fileURL)
                    == reusable.serializedByteCount,
               let existing: PersistedPendingReviewFile = Self.loadEntry(at: fileURL),
               existing.version == Self.schemaVersion, existing.key == fileKey,
               existing.diff == diff {
                descriptors.append(reusable)
                touchCacheFile(at: fileURL)
                continue
            }
            // 旧 manifest 不能在更新途中继续把新旧混合的段标为完整缓存。
            if !invalidatedPreviousManifest {
                try removeCacheFileIfPresent(at: manifestURL)
                invalidatedPreviousManifest = true
            }
            let fileEntry = PersistedPendingReviewFile(
                version: Self.schemaVersion,
                key: fileKey,
                diff: diff
            )
            guard let byteCount = try save(
                fileEntry,
                to: fileURL,
                prunesCache: false
            ) else {
                removePendingSegments(for: key)
                return nil
            }
            descriptors.append(
                PendingReviewFileDescriptor(
                    changeID: diff.change.id,
                    scope: diff.scope,
                    serializedByteCount: byteCount
                )
            )
            writtenURLs.append(fileURL)
        }
        let segmentByteCount = descriptors.reduce(0) {
            $0 + $1.serializedByteCount
        }
        guard segmentByteCount <= Self.maximumCacheByteCount else {
            removePendingSegments(for: key)
            return nil
        }
        let manifest = PersistedPendingReviewManifest(
            version: Self.schemaVersion,
            key: key,
            files: descriptors,
            isComplete: isComplete
        )
        guard let manifestByteCount = try save(
            manifest,
            to: manifestURL,
            prunesCache: false
        ) else {
            return nil
        }
        guard segmentByteCount + manifestByteCount <= Self.maximumCacheByteCount else {
            removePendingSegments(for: key)
            return nil
        }
        let nextFileKeys = Set(descriptors.map {
            $0.cacheKey(pendingKeyDigest: pendingKeyDigest)
        })
        if previousManifest?.version == Self.schemaVersion,
           previousManifest?.key == key {
            for descriptor in previousManifest?.files ?? [] {
                let previousKey = descriptor.cacheKey(
                    pendingKeyDigest: pendingKeyDigest
                )
                guard !nextFileKeys.contains(previousKey) else {
                    continue
                }
                removeInvalidCacheFile(
                    at: Self.cacheFileURL(
                        directoryURL: directoryURL,
                        prefix: "pending-file",
                        key: previousKey
                    )
                )
            }
        }
        completed = true
        return segmentByteCount + manifestByteCount
    }

    private func loadPendingSegments(
        for key: PendingReviewContentCacheKey
    ) -> LoadedPendingReviewSegments? {
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "pending-manifest",
            key: key
        )
        guard let manifest: PersistedPendingReviewManifest = Self.loadEntry(
            at: manifestURL
        ), manifest.version == Self.schemaVersion,
              manifest.key == key else {
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                removeInvalidCacheFile(at: manifestURL)
            }
            return nil
        }
        var diffs: [GitFileDiff] = []
        var serializedByteCount = Self.cacheFileByteCount(at: manifestURL)
        let pendingKeyDigest = Self.cacheKeyDigest(key)
        for descriptor in manifest.files {
            let fileKey = descriptor.cacheKey(
                pendingKeyDigest: pendingKeyDigest
            )
            let fileURL = Self.cacheFileURL(
                directoryURL: directoryURL,
                prefix: "pending-file",
                key: fileKey
            )
            let remainingByteCount = Self.maximumCacheByteCount - serializedByteCount
            guard let entry: PersistedPendingReviewFile = Self.loadEntry(
                at: fileURL,
                maximumByteCount: min(Self.maximumEntryByteCount, remainingByteCount)
            ), entry.version == Self.schemaVersion,
                  entry.key == fileKey else {
                removePendingSegments(for: key)
                return nil
            }
            diffs.append(entry.diff)
            serializedByteCount += Self.cacheFileByteCount(at: fileURL)
            touchCacheFile(at: fileURL)
        }
        touchCacheFile(at: manifestURL)
        return LoadedPendingReviewSegments(
            diffs: diffs,
            serializedByteCount: serializedByteCount,
            isComplete: manifest.isComplete
        )
    }

    private func removePendingSegments(
        for key: PendingReviewContentCacheKey
    ) {
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "pending-manifest",
            key: key
        )
        if let manifest: PersistedPendingReviewManifest = Self.loadEntry(
            at: manifestURL
        ), manifest.version == Self.schemaVersion,
           manifest.key == key {
            let pendingKeyDigest = Self.cacheKeyDigest(key)
            for descriptor in manifest.files {
                removeInvalidCacheFile(
                    at: Self.cacheFileURL(
                        directoryURL: directoryURL,
                        prefix: "pending-file",
                        key: descriptor.cacheKey(
                            pendingKeyDigest: pendingKeyDigest
                        )
                    )
                )
            }
        }
        removeInvalidCacheFile(at: manifestURL)
    }

    func historicalDetails(
        for key: HistoricalReviewDetailsCacheKey
    ) -> HistoricalReviewDetails? {
        if let details = historicalDetailsByKey[key] {
            touchMemoryCache(.historicalDetails(key))
            return details
        }
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-details",
            key: key
        )
        guard let entry: PersistedHistoricalReviewDetails = Self.loadEntry(at: fileURL),
              entry.version == Self.schemaVersion,
              entry.key == key else {
            removeInvalidCacheFile(at: fileURL)
            return nil
        }
        historicalDetailsByKey[key] = entry.details
        rememberMemoryCache(
            .historicalDetails(key),
            serializedByteCount: Self.cacheFileByteCount(at: fileURL)
        )
        touchCacheFile(at: fileURL)
        return entry.details
    }

    func saveHistoricalDetails(
        _ details: HistoricalReviewDetails,
        for key: HistoricalReviewDetailsCacheKey
    ) throws {
        let entry = PersistedHistoricalReviewDetails(
            version: Self.schemaVersion,
            key: key,
            details: details
        )
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-details",
            key: key
        )
        if let byteCount = try save(
            entry,
            to: fileURL
        ) {
            historicalDetailsByKey[key] = details
            rememberMemoryCache(
                .historicalDetails(key),
                serializedByteCount: byteCount
            )
        } else {
            removeMemoryCacheValue(for: .historicalDetails(key))
        }
    }

    func historicalDiffs(
        for key: HistoricalReviewDiffCacheKey
    ) -> [GitFileDiff]? {
        historicalDiffEntry(for: key)?.diffs
    }

    func historicalDiffEntry(
        for key: HistoricalReviewDiffCacheKey
    ) -> ReviewDiffCacheEntry? {
        if let diffs = historicalDiffsByKey[key] {
            touchMemoryCache(.historicalDiff(key))
            return ReviewDiffCacheEntry(
                diffs: diffs,
                isComplete: historicalDiffCompletenessByKey[key] ?? true
            )
        }
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-diff",
            key: key
        )
        if let entry: PersistedHistoricalReviewDiff = Self.loadEntry(at: fileURL),
           entry.version == Self.schemaVersion,
           entry.key == key {
            historicalDiffsByKey[key] = entry.diffs
            historicalDiffCompletenessByKey[key] = true
            rememberMemoryCache(
                .historicalDiff(key),
                serializedByteCount: Self.cacheFileByteCount(at: fileURL)
            )
            touchCacheFile(at: fileURL)
            return ReviewDiffCacheEntry(
                diffs: entry.diffs,
                isComplete: true
            )
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            removeInvalidCacheFile(at: fileURL)
        }
        guard let segmented = loadHistoricalSegments(for: key) else {
            return nil
        }
        historicalDiffsByKey[key] = segmented.diffs
        historicalDiffCompletenessByKey[key] = segmented.isComplete
        rememberMemoryCache(
            .historicalDiff(key),
            serializedByteCount: segmented.serializedByteCount
        )
        return ReviewDiffCacheEntry(
            diffs: segmented.diffs,
            isComplete: segmented.isComplete
        )
    }

    func saveHistoricalDiffs(
        _ diffs: [GitFileDiff],
        for key: HistoricalReviewDiffCacheKey
    ) throws {
        let sortedDiffs = diffs.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return lhs.scope.rawValue < rhs.scope.rawValue
            }
            return lhs.change.id < rhs.change.id
        }
        let entry = PersistedHistoricalReviewDiff(
            version: Self.schemaVersion,
            key: key,
            diffs: sortedDiffs
        )
        let fileURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-diff",
            key: key
        )
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL, prefix: "historical-diff-manifest", key: key
        )
        let manifest: PersistedHistoricalReviewManifest? = Self.loadEntry(at: manifestURL)
        let hasSegments = manifest?.version == Self.schemaVersion && manifest?.key == key
        let aggregateByteCount = hasSegments ? nil : try save(
            entry,
            to: fileURL,
            prunesCache: false,
            maximumByteCount: Self.maximumStartupEntryByteCount
        )
        let segmentedByteCount: Int?
        if aggregateByteCount == nil {
            try removeCacheFileIfPresent(at: fileURL)
            segmentedByteCount = try saveHistoricalSegments(
                sortedDiffs,
                for: key,
                isComplete: true
            )
        } else {
            removeHistoricalSegments(for: key)
            segmentedByteCount = nil
        }
        try pruneIfNeeded()
        if let serializedByteCount = aggregateByteCount ?? segmentedByteCount {
            historicalDiffsByKey[key] = sortedDiffs
            historicalDiffCompletenessByKey[key] = true
            rememberMemoryCache(
                .historicalDiff(key),
                serializedByteCount: serializedByteCount
            )
        } else {
            removeMemoryCacheValue(for: .historicalDiff(key))
        }
    }

    func savePartialHistoricalDiffs(
        _ diffs: [GitFileDiff],
        for key: HistoricalReviewDiffCacheKey
    ) throws {
        let sortedDiffs = diffs.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return lhs.scope.rawValue < rhs.scope.rawValue
            }
            return lhs.change.id < rhs.change.id
        }
        let aggregateURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-diff",
            key: key
        )
        try removeCacheFileIfPresent(at: aggregateURL)
        let serializedByteCount = try saveHistoricalSegments(
            sortedDiffs,
            for: key,
            isComplete: false
        )
        try pruneIfNeeded()
        if let serializedByteCount {
            historicalDiffsByKey[key] = sortedDiffs
            historicalDiffCompletenessByKey[key] = false
            rememberMemoryCache(
                .historicalDiff(key),
                serializedByteCount: serializedByteCount
            )
        } else {
            removeMemoryCacheValue(for: .historicalDiff(key))
        }
    }

    func historicalDiff(
        changeID: GitFileChange.ID,
        for key: HistoricalReviewDiffCacheKey
    ) -> GitFileDiff? {
        historicalDiffs(for: key)?.first { $0.change.id == changeID }
    }

    func saveHistoricalDiff(
        _ diff: GitFileDiff,
        for key: HistoricalReviewDiffCacheKey
    ) throws {
        let existing = historicalDiffEntry(for: key)
        var diffs = existing?.diffs ?? []
        diffs.removeAll { $0.change.id == diff.change.id }
        diffs.append(diff)
        let sortedDiffs = diffs.sorted { $0.change.id < $1.change.id }
        let isComplete = existing?.isComplete == true
        let aggregateURL = Self.cacheFileURL(
            directoryURL: directoryURL, prefix: "historical-diff", key: key
        )
        try removeCacheFileIfPresent(at: aggregateURL)
        let serializedByteCount = try saveHistoricalSegments(sortedDiffs, for: key, isComplete: isComplete)
        try pruneIfNeeded()
        if let serializedByteCount {
            historicalDiffsByKey[key] = sortedDiffs
            historicalDiffCompletenessByKey[key] = isComplete
            rememberMemoryCache(.historicalDiff(key), serializedByteCount: serializedByteCount)
        } else {
            removeMemoryCacheValue(for: .historicalDiff(key))
        }
    }

    private func saveHistoricalSegments(
        _ diffs: [GitFileDiff],
        for key: HistoricalReviewDiffCacheKey,
        isComplete: Bool
    ) throws -> Int? {
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-diff-manifest",
            key: key
        )
        let previousManifest: PersistedHistoricalReviewManifest? = Self.loadEntry(
            at: manifestURL
        )
        let historicalKeyDigest = Self.cacheKeyDigest(key)
        let previousDescriptors: [HistoricalReviewFileDescriptor] = if
            previousManifest?.version == Self.schemaVersion,
            previousManifest?.key == key {
            previousManifest?.files ?? []
        } else {
            []
        }
        let reusableDescriptors: [
            HistoricalReviewFileCacheKey: HistoricalReviewFileDescriptor
        ] = Dictionary(
            previousDescriptors.map {
                ($0.cacheKey(historicalKeyDigest: historicalKeyDigest), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var descriptors: [HistoricalReviewFileDescriptor] = []
        var writtenURLs: [URL] = []
        var invalidatedPreviousManifest = false
        var completed = false
        defer {
            if !completed {
                for fileURL in writtenURLs {
                    try? removeCacheFile(at: fileURL)
                }
            }
        }
        for diff in diffs {
            let fileKey = HistoricalReviewFileCacheKey(
                historicalKeyDigest: historicalKeyDigest,
                changeID: diff.change.id,
                scope: diff.scope
            )
            let fileURL = Self.cacheFileURL(
                directoryURL: directoryURL,
                prefix: "historical-diff-file",
                key: fileKey
            )
            if let reusable = reusableDescriptors[fileKey],
               Self.cacheFileByteCount(at: fileURL)
                    == reusable.serializedByteCount,
               let existing: PersistedHistoricalReviewFile = Self.loadEntry(at: fileURL),
               existing.version == Self.schemaVersion, existing.key == fileKey,
               existing.diff == diff {
                descriptors.append(reusable)
                touchCacheFile(at: fileURL)
                continue
            }
            if !invalidatedPreviousManifest {
                try removeCacheFileIfPresent(at: manifestURL)
                invalidatedPreviousManifest = true
            }
            let fileEntry = PersistedHistoricalReviewFile(
                version: Self.schemaVersion,
                key: fileKey,
                diff: diff
            )
            guard let byteCount = try save(
                fileEntry,
                to: fileURL,
                prunesCache: false
            ) else {
                removeHistoricalSegments(for: key)
                return nil
            }
            descriptors.append(
                HistoricalReviewFileDescriptor(
                    changeID: diff.change.id,
                    scope: diff.scope,
                    serializedByteCount: byteCount
                )
            )
            writtenURLs.append(fileURL)
        }
        let segmentByteCount = descriptors.reduce(0) {
            $0 + $1.serializedByteCount
        }
        guard segmentByteCount <= Self.maximumCacheByteCount else {
            removeHistoricalSegments(for: key)
            return nil
        }
        let manifest = PersistedHistoricalReviewManifest(
            version: Self.schemaVersion,
            key: key,
            files: descriptors,
            isComplete: isComplete
        )
        guard let manifestByteCount = try save(
            manifest,
            to: manifestURL,
            prunesCache: false
        ) else {
            return nil
        }
        guard segmentByteCount + manifestByteCount <= Self.maximumCacheByteCount else {
            removeHistoricalSegments(for: key)
            return nil
        }
        let nextFileKeys = Set(descriptors.map {
            $0.cacheKey(historicalKeyDigest: historicalKeyDigest)
        })
        if previousManifest?.version == Self.schemaVersion,
           previousManifest?.key == key {
            for descriptor in previousManifest?.files ?? [] {
                let previousKey = descriptor.cacheKey(
                    historicalKeyDigest: historicalKeyDigest
                )
                guard !nextFileKeys.contains(previousKey) else {
                    continue
                }
                removeInvalidCacheFile(
                    at: Self.cacheFileURL(
                        directoryURL: directoryURL,
                        prefix: "historical-diff-file",
                        key: previousKey
                    )
                )
            }
        }
        completed = true
        return segmentByteCount + manifestByteCount
    }

    private func loadHistoricalSegments(
        for key: HistoricalReviewDiffCacheKey
    ) -> LoadedHistoricalReviewSegments? {
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-diff-manifest",
            key: key
        )
        guard let manifest: PersistedHistoricalReviewManifest = Self.loadEntry(
            at: manifestURL
        ), manifest.version == Self.schemaVersion,
              manifest.key == key else {
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                removeInvalidCacheFile(at: manifestURL)
            }
            return nil
        }
        let historicalKeyDigest = Self.cacheKeyDigest(key)
        var diffs: [GitFileDiff] = []
        var serializedByteCount = Self.cacheFileByteCount(at: manifestURL)
        for descriptor in manifest.files {
            let fileKey = descriptor.cacheKey(
                historicalKeyDigest: historicalKeyDigest
            )
            let fileURL = Self.cacheFileURL(
                directoryURL: directoryURL,
                prefix: "historical-diff-file",
                key: fileKey
            )
            let remainingByteCount = Self.maximumCacheByteCount - serializedByteCount
            guard let entry: PersistedHistoricalReviewFile = Self.loadEntry(
                at: fileURL,
                maximumByteCount: min(Self.maximumEntryByteCount, remainingByteCount)
            ), entry.version == Self.schemaVersion,
                  entry.key == fileKey else {
                removeHistoricalSegments(for: key)
                return nil
            }
            diffs.append(entry.diff)
            serializedByteCount += Self.cacheFileByteCount(at: fileURL)
            touchCacheFile(at: fileURL)
        }
        touchCacheFile(at: manifestURL)
        return LoadedHistoricalReviewSegments(
            diffs: diffs,
            serializedByteCount: serializedByteCount,
            isComplete: manifest.isComplete
        )
    }

    private func removeHistoricalSegments(
        for key: HistoricalReviewDiffCacheKey
    ) {
        let manifestURL = Self.cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-diff-manifest",
            key: key
        )
        if let manifest: PersistedHistoricalReviewManifest = Self.loadEntry(
            at: manifestURL
        ), manifest.version == Self.schemaVersion,
           manifest.key == key {
            let historicalKeyDigest = Self.cacheKeyDigest(key)
            for descriptor in manifest.files {
                removeInvalidCacheFile(
                    at: Self.cacheFileURL(
                        directoryURL: directoryURL,
                        prefix: "historical-diff-file",
                        key: descriptor.cacheKey(
                            historicalKeyDigest: historicalKeyDigest
                        )
                    )
                )
            }
        }
        removeInvalidCacheFile(at: manifestURL)
    }

    private nonisolated static func loadStartupPendingSegments(
        directoryURL: URL,
        key: PendingReviewContentCacheKey,
        maximumByteCount: Int
    ) -> StartupPendingReviewContent? {
        let manifestURL = cacheFileURL(
            directoryURL: directoryURL,
            prefix: "pending-manifest",
            key: key
        )
        guard let manifest: PersistedPendingReviewManifest = loadEntry(
            at: manifestURL,
            maximumByteCount: maximumByteCount
        ), manifest.version == schemaVersion,
              manifest.key == key else {
            return nil
        }
        var remainingByteCount = max(
            0,
            maximumByteCount - cacheFileByteCount(at: manifestURL)
        )
        var diffs: [GitFileDiff] = []
        let pendingKeyDigest = cacheKeyDigest(key)
        for descriptor in manifest.files {
            guard descriptor.serializedByteCount > 0,
                  descriptor.serializedByteCount <= remainingByteCount else {
                continue
            }
            let fileKey = descriptor.cacheKey(
                pendingKeyDigest: pendingKeyDigest
            )
            let fileURL = cacheFileURL(
                directoryURL: directoryURL,
                prefix: "pending-file",
                key: fileKey
            )
            guard let entry: PersistedPendingReviewFile = loadEntry(
                at: fileURL,
                maximumByteCount: remainingByteCount
            ), entry.version == schemaVersion,
                  entry.key == fileKey else {
                continue
            }
            diffs.append(entry.diff)
            remainingByteCount -= cacheFileByteCount(at: fileURL)
        }
        return StartupPendingReviewContent(
            diffs: diffs,
            isComplete: manifest.isComplete
                && diffs.count == manifest.files.count
        )
    }

    private nonisolated static func loadStartupHistoricalSegments(
        directoryURL: URL,
        key: HistoricalReviewDiffCacheKey,
        maximumByteCount: Int
    ) -> StartupHistoricalReviewContent? {
        let manifestURL = cacheFileURL(
            directoryURL: directoryURL,
            prefix: "historical-diff-manifest",
            key: key
        )
        guard let manifest: PersistedHistoricalReviewManifest = loadEntry(
            at: manifestURL,
            maximumByteCount: maximumByteCount
        ), manifest.version == schemaVersion,
              manifest.key == key else {
            return nil
        }
        var remainingByteCount = max(
            0,
            maximumByteCount - cacheFileByteCount(at: manifestURL)
        )
        var diffs: [GitFileDiff] = []
        let historicalKeyDigest = cacheKeyDigest(key)
        for descriptor in manifest.files {
            guard descriptor.serializedByteCount > 0,
                  descriptor.serializedByteCount <= remainingByteCount else {
                continue
            }
            let fileKey = descriptor.cacheKey(
                historicalKeyDigest: historicalKeyDigest
            )
            let fileURL = cacheFileURL(
                directoryURL: directoryURL,
                prefix: "historical-diff-file",
                key: fileKey
            )
            guard let entry: PersistedHistoricalReviewFile = loadEntry(
                at: fileURL,
                maximumByteCount: remainingByteCount
            ), entry.version == schemaVersion,
                  entry.key == fileKey else {
                continue
            }
            diffs.append(entry.diff)
            remainingByteCount -= cacheFileByteCount(at: fileURL)
        }
        return StartupHistoricalReviewContent(
            diffs: diffs,
            isComplete: manifest.isComplete
                && diffs.count == manifest.files.count
        )
    }

    private nonisolated static func loadEntry<Value: Decodable>(
        at fileURL: URL,
        maximumByteCount: Int = maximumEntryByteCount
    ) -> Value? {
        guard let data = loadCacheData(
            at: fileURL,
            maximumByteCount: maximumByteCount
        ) else {
            return nil
        }
        return try? makeDecoder().decode(Value.self, from: data)
    }

    private nonisolated static func loadCacheData(
        at fileURL: URL,
        maximumByteCount: Int
    ) -> Data? {
        var uncachedURL = fileURL
        uncachedURL.removeAllCachedResourceValues()
        guard let values = try? uncachedURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey
        ]), values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize <= maximumByteCount else {
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= maximumByteCount else {
            return nil
        }
        return data
    }

    private nonisolated static func cacheFileByteCount(at fileURL: URL) -> Int {
        var uncachedURL = fileURL
        uncachedURL.removeAllCachedResourceValues()
        return (try? uncachedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1
    }

    private func save<Value: Encodable>(
        _ value: Value,
        to fileURL: URL,
        prunesCache: Bool = true,
        maximumByteCount: Int = ReviewContentStore.maximumEntryByteCount
    ) throws -> Int? {
        let data = try Self.makeEncoder().encode(value)
        guard data.count <= maximumByteCount else {
            removeInvalidCacheFile(at: fileURL)
            return nil
        }
        if Self.existingCacheFileByteCount(at: fileURL) == data.count,
           Self.loadCacheData(at: fileURL, maximumByteCount: data.count) == data {
            touchCacheFile(at: fileURL)
            if prunesCache {
                try pruneIfNeeded()
            }
            return data.count
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = try refreshCacheFileIndexIfNeeded()
        let previousByteCount = Self.existingCacheFileByteCount(at: fileURL)
        try data.write(to: fileURL, options: .atomic)
        recordCacheFileWrite(at: fileURL, byteCount: data.count, previousByteCount: previousByteCount)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        if prunesCache {
            try pruneIfNeeded()
        }
        return data.count
    }

    private func rememberMemoryCache(
        _ key: ReviewMemoryCacheKey,
        serializedByteCount: Int
    ) {
        if let previous = memoryCacheMetadata[key] {
            memoryCacheByteCount -= previous.serializedByteCount
        }
        memoryCacheAccessSequence &+= 1
        let normalizedByteCount = max(1, serializedByteCount)
        memoryCacheMetadata[key] = ReviewMemoryCacheMetadata(
            serializedByteCount: normalizedByteCount,
            accessSequence: memoryCacheAccessSequence
        )
        memoryCacheByteCount += normalizedByteCount
        pruneMemoryCacheIfNeeded()
    }

    private func touchMemoryCache(_ key: ReviewMemoryCacheKey) {
        guard let current = memoryCacheMetadata[key] else {
            return
        }
        memoryCacheAccessSequence &+= 1
        memoryCacheMetadata[key] = ReviewMemoryCacheMetadata(
            serializedByteCount: current.serializedByteCount,
            accessSequence: memoryCacheAccessSequence
        )
    }

    private func pruneMemoryCacheIfNeeded() {
        while memoryCacheMetadata.count > maximumMemoryCacheEntryCount
            || memoryCacheByteCount > maximumMemoryCacheByteCount {
            guard let oldest = memoryCacheMetadata.min(by: {
                $0.value.accessSequence < $1.value.accessSequence
            })?.key else {
                return
            }
            removeMemoryCacheValue(for: oldest)
        }
    }

    private func removeMemoryCacheValue(for key: ReviewMemoryCacheKey) {
        if let metadata = memoryCacheMetadata.removeValue(forKey: key) {
            memoryCacheByteCount -= metadata.serializedByteCount
        }
        switch key {
        case let .history(cacheKey):
            historyPages[cacheKey] = nil
        case let .pending(cacheKey):
            pendingDiffsByKey[cacheKey] = nil
            pendingDiffCompletenessByKey[cacheKey] = nil
        case let .pendingFile(identity):
            reusablePendingDiffs[identity] = nil
        case let .historicalDetails(cacheKey):
            historicalDetailsByKey[cacheKey] = nil
        case let .historicalDiff(cacheKey):
            historicalDiffsByKey[cacheKey] = nil
            historicalDiffCompletenessByKey[cacheKey] = nil
        }
    }

    private func pruneIfNeeded() throws {
        let scannedFiles = try refreshCacheFileIndexIfNeeded()
        guard knownCacheByteCount ?? 0 > Self.maximumCacheByteCount else {
            return
        }
        let files: [CacheFile]
        if let cacheFilesByURL {
            files = Array(cacheFilesByURL.values)
        } else if let scannedFiles {
            files = scannedFiles
        } else {
            // 外部目录文件过多时不把全部索引长期留在内存，按需扫描清理。
            files = try scanCacheDirectory()
        }
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            do {
                try removeCacheFile(at: file.url, refreshesIndex: false)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                forgetCacheFile(at: file.url, previousByteCount: file.size)
            }
            if knownCacheByteCount ?? 0 <= Self.cachePruningTargetByteCount {
                break
            }
        }
    }

    /// 自身写入、删除后记录目录时间，下一次保存只检查一个目录属性。
    /// 外部新增、删除会触发重建；原地修改已有文件由定期扫描核对。
    private func refreshCacheFileIndexIfNeeded() throws -> [CacheFile]? {
        let now = Date()
        let age = now.timeIntervalSince(lastCacheDirectoryScan)
        if knownCacheByteCount != nil, age >= 0, age < 60,
           cacheDirectoryModifiedAt == currentCacheDirectoryModificationDate() {
            return nil
        }
        return try scanCacheDirectory()
    }

    private func scanCacheDirectory() throws -> [CacheFile] {
        let directoryModifiedAt = currentCacheDirectoryModificationDate()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { fileURL -> CacheFile? in
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                return nil
            }
            return CacheFile(
                url: fileURL,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        knownCacheByteCount = files.reduce(0) { $0 + $1.size }
        cacheFilesByURL = files.count <= Self.maximumIndexedCacheFileCount
            ? Dictionary(files.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            : nil
        lastCacheDirectoryScan = Date()
        cacheDirectoryModifiedAt = directoryModifiedAt
        return files
    }

    private func currentCacheDirectoryModificationDate() -> Date? {
        var url = directoryURL
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func recordCacheFileWrite(at fileURL: URL, byteCount: Int, previousByteCount: Int) {
        let previousSize = cacheFilesByURL?[fileURL]?.size ?? previousByteCount
        if let knownCacheByteCount {
            self.knownCacheByteCount = max(0, knownCacheByteCount - previousSize + byteCount)
        }
        if cacheFilesByURL != nil {
            if cacheFilesByURL?[fileURL] == nil,
               cacheFilesByURL?.count ?? 0 >= Self.maximumIndexedCacheFileCount {
                cacheFilesByURL = nil
            } else {
                cacheFilesByURL?[fileURL] = CacheFile(url: fileURL, size: byteCount, modifiedAt: Date())
            }
        }
        cacheDirectoryModifiedAt = currentCacheDirectoryModificationDate()
    }

    private func forgetCacheFile(at fileURL: URL, previousByteCount: Int) {
        let previousSize = cacheFilesByURL?.removeValue(forKey: fileURL)?.size ?? previousByteCount
        if let knownCacheByteCount {
            self.knownCacheByteCount = max(0, knownCacheByteCount - previousSize)
        }
        cacheDirectoryModifiedAt = currentCacheDirectoryModificationDate()
    }

    private nonisolated static func cacheFileURL<Key: Encodable>(
        directoryURL: URL,
        prefix: String,
        key: Key
    ) -> URL {
        let digest = cacheKeyDigest(key)
        return directoryURL.appendingPathComponent(
            "\(prefix)-\(digest).json",
            isDirectory: false
        )
    }

    private nonisolated static func cacheKeyDigest<Key: Encodable>(
        _ key: Key
    ) -> String {
        let keyData = (try? Self.makeEncoder().encode(key)) ?? Data()
        return SHA256.hash(data: keyData).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func removeInvalidCacheFile(at fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try? removeCacheFile(at: fileURL)
    }

    private func removeCacheFileIfPresent(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try removeCacheFile(at: fileURL)
    }

    private nonisolated static func existingCacheFileByteCount(at fileURL: URL) -> Int {
        var uncachedURL = fileURL
        uncachedURL.removeAllCachedResourceValues()
        return (try? uncachedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func removeCacheFile(at fileURL: URL, refreshesIndex: Bool = true) throws {
        if refreshesIndex, knownCacheByteCount != nil {
            _ = try refreshCacheFileIndexIfNeeded()
        }
        let byteCount = Self.existingCacheFileByteCount(at: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        forgetCacheFile(at: fileURL, previousByteCount: byteCount)
    }

    private func touchCacheFile(at fileURL: URL) {
        let now = Date()
        if let file = cacheFilesByURL?[fileURL] {
            let age = now.timeIntervalSince(file.modifiedAt)
            if age >= 0, age < Self.cacheFileTouchInterval {
                return
            }
        }
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: now], ofItemAtPath: fileURL.path
            )
            if let file = cacheFilesByURL?[fileURL] {
                let size = Self.existingCacheFileByteCount(at: fileURL)
                if let knownCacheByteCount {
                    self.knownCacheByteCount = max(0, knownCacheByteCount - file.size + size)
                }
                cacheFilesByURL?[fileURL] = CacheFile(url: fileURL, size: size, modifiedAt: now)
            }
        } catch {
            // 外部删除或替换失败时，让下一次保存重新核对目录。
            knownCacheByteCount = nil
            cacheFilesByURL = nil
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct PersistedHistoryReviewContent: Codable {
    let version: Int
    let key: HistoryReviewContentCacheKey
    let page: GitHistoryPage
}

private struct PersistedPendingReviewContent: Codable {
    let version: Int
    let key: PendingReviewContentCacheKey
    let diffs: [GitFileDiff]
}

private struct PersistedReusablePendingFile: Codable {
    let version: Int
    let identity: GitPendingDiffIdentity
    let diff: GitFileDiff
}

private struct PersistedPendingReviewManifest: Codable {
    let version: Int
    let key: PendingReviewContentCacheKey
    let files: [PendingReviewFileDescriptor]
    let isComplete: Bool

    private enum CodingKeys: String, CodingKey {
        case version
        case key
        case files
        case isComplete
    }

    init(
        version: Int,
        key: PendingReviewContentCacheKey,
        files: [PendingReviewFileDescriptor],
        isComplete: Bool
    ) {
        self.version = version
        self.key = key
        self.files = files
        self.isComplete = isComplete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        key = try container.decode(PendingReviewContentCacheKey.self, forKey: .key)
        files = try container.decode(
            [PendingReviewFileDescriptor].self,
            forKey: .files
        )
        isComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .isComplete
        ) ?? true
    }
}

private struct PersistedPendingReviewFile: Codable {
    let version: Int
    let key: PendingReviewFileCacheKey
    let diff: GitFileDiff
}

private struct PersistedHistoricalReviewDetails: Codable {
    let version: Int
    let key: HistoricalReviewDetailsCacheKey
    let details: HistoricalReviewDetails
}

private struct PersistedHistoricalReviewDiff: Codable {
    let version: Int
    let key: HistoricalReviewDiffCacheKey
    let diffs: [GitFileDiff]
}

private struct PersistedHistoricalReviewManifest: Codable {
    let version: Int
    let key: HistoricalReviewDiffCacheKey
    let files: [HistoricalReviewFileDescriptor]
    let isComplete: Bool

    private enum CodingKeys: String, CodingKey {
        case version
        case key
        case files
        case isComplete
    }

    init(
        version: Int,
        key: HistoricalReviewDiffCacheKey,
        files: [HistoricalReviewFileDescriptor],
        isComplete: Bool
    ) {
        self.version = version
        self.key = key
        self.files = files
        self.isComplete = isComplete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        key = try container.decode(
            HistoricalReviewDiffCacheKey.self,
            forKey: .key
        )
        files = try container.decode(
            [HistoricalReviewFileDescriptor].self,
            forKey: .files
        )
        isComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .isComplete
        ) ?? true
    }
}

private struct PersistedHistoricalReviewFile: Codable {
    let version: Int
    let key: HistoricalReviewFileCacheKey
    let diff: GitFileDiff
}

private struct CacheFile {
    let url: URL
    let size: Int
    let modifiedAt: Date
}
