import AgentGitCore
import Foundation

/// 一次 Review 的上下文。Pending、单 commit、commit range 共用同一套状态与同一个 Review 流。
enum ReviewContext: Hashable, Codable, Sendable {
    case pending
    case commit(GitCommit.ID)
    case range(base: GitCommit.ID, head: GitCommit.ID)
}

enum ReviewPane: String, Hashable, Codable, Sendable, CaseIterable, Identifiable {
    case commits
    case files

    var id: Self { self }

    var title: String {
        switch self {
        case .commits: "Commits"
        case .files: "Files"
        }
    }
}

enum DiffLayoutMode: String, Hashable, CaseIterable, Identifiable {
    case unified
    case sideBySide

    var id: Self { self }

    var title: String {
        switch self {
        case .unified: "Unified"
        case .sideBySide: "Split"
        }
    }
}

/// 折叠、聚焦、过滤走 SwiftUI 状态；滚动位置单独存，由 AppKit 直接读写。
struct ReviewState: Equatable {
    var collapsedFileIDs: Set<String> = []
    var knownFileIDs: Set<String> = []
    var expandedNavigatorFolderIDs: Set<String> = []
    var focusedFileID: String?
    var filterText = ""
    var reviewedSnapshotByFileID: [String: DiffReviewSnapshotID] = [:]
    var wholeFileIDs: Set<String> = []
    var revealedContextLineCountByGapID: [String: Int] = [:]
}

struct DiffReviewSnapshotID: Hashable, Codable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(diff: GitFileDiff, externalSeed: String? = nil) {
        var fingerprint = StableDiffFingerprint()
        fingerprint.combine(externalSeed)
        fingerprint.combine(diff.change.path)
        fingerprint.combine(diff.change.originalPath)
        fingerprint.combine(diff.scope.rawValue)
        fingerprint.combine(String(diff.change.indexStatus))
        fingerprint.combine(String(diff.change.worktreeStatus))
        switch diff.state {
        case .textual:
            fingerprint.combine("textual")
        case let .metadata(summary):
            fingerprint.combine("metadata")
            fingerprint.combine(summary)
        case .binary:
            fingerprint.combine("binary")
        case let .tooLarge(lineCount):
            fingerprint.combine("too-large")
            fingerprint.combine(lineCount)
        case let .unavailable(reason):
            fingerprint.combine("unavailable")
            fingerprint.combine(reason)
        }
        for line in diff.hunks.flatMap(\.lines) where line.kind != .context {
            switch line.kind {
            case .context: break
            case .addition: fingerprint.combine(1)
            case .deletion: fingerprint.combine(2)
            case .metadata: fingerprint.combine(3)
            }
            fingerprint.combine(line.oldLineNumber)
            fingerprint.combine(line.newLineNumber)
            fingerprint.combine(line.content)
        }
        rawValue = fingerprint.value
    }
}

private struct StableDiffFingerprint {
    private(set) var value: UInt64 = 14_695_981_039_346_656_037

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            combineByte(byte)
        }
        combineByte(0xFF)
    }

    mutating func combine(_ string: String?) {
        guard let string else {
            combineByte(0xFE)
            return
        }
        combineByte(0x01)
        combine(string)
    }

    mutating func combine(_ integer: Int) {
        var bytes = UInt64(bitPattern: Int64(integer)).littleEndian
        withUnsafeBytes(of: &bytes) { buffer in
            for byte in buffer {
                combineByte(byte)
            }
        }
        combineByte(0xFD)
    }

    mutating func combine(_ integer: Int?) {
        guard let integer else {
            combineByte(0xFC)
            return
        }
        combineByte(0x01)
        combine(integer)
    }

    private mutating func combineByte(_ byte: UInt8) {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }
}

struct ReviewStateKey: Hashable, Codable, Sendable {
    let worktreeID: GitWorktreeSnapshot.ID
    let context: ReviewContext
}

struct ReviewNavigationState: Hashable, Codable, Sendable {
    let context: ReviewContext
    let selectedCommitIDs: Set<GitCommit.ID>
    let pane: ReviewPane
    let historyFilter: String

    private enum CodingKeys: String, CodingKey {
        case context
        case selectedCommitIDs
        case pane
        case historyFilter
    }

    init(
        context: ReviewContext,
        selectedCommitIDs: Set<GitCommit.ID>,
        pane: ReviewPane = .commits,
        historyFilter: String = ""
    ) {
        self.context = context
        self.selectedCommitIDs = selectedCommitIDs
        self.pane = pane
        self.historyFilter = historyFilter
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        context = try container.decode(ReviewContext.self, forKey: .context)
        selectedCommitIDs = try container.decode(
            Set<GitCommit.ID>.self,
            forKey: .selectedCommitIDs
        )
        pane = try container.decodeIfPresent(
            ReviewPane.self,
            forKey: .pane
        ) ?? .commits
        historyFilter = try container.decodeIfPresent(
            String.self,
            forKey: .historyFilter
        ) ?? ""
    }

    static let pending = ReviewNavigationState(
        context: .pending,
        selectedCommitIDs: [],
        pane: .commits,
        historyFilter: ""
    )
}

struct ReviewNavigationHistory: Equatable, Sendable {
    private let maximumEntryCount: Int
    private var backStack: [ReviewNavigationState] = []
    private var forwardStack: [ReviewNavigationState] = []

    init(maximumEntryCount: Int = 50) {
        self.maximumEntryCount = max(0, maximumEntryCount)
    }

    var canNavigateBack: Bool { !backStack.isEmpty }
    var canNavigateForward: Bool { !forwardStack.isEmpty }

    mutating func recordTransition(
        from previous: ReviewNavigationState,
        to current: ReviewNavigationState
    ) {
        guard previous != current else {
            return
        }
        Self.append(
            previous,
            to: &backStack,
            maximumEntryCount: maximumEntryCount
        )
        forwardStack = []
    }

    mutating func navigateBack(
        from current: ReviewNavigationState
    ) -> ReviewNavigationState? {
        guard let target = backStack.popLast() else {
            return nil
        }
        Self.append(
            current,
            to: &forwardStack,
            maximumEntryCount: maximumEntryCount
        )
        return target
    }

    mutating func navigateForward(
        from current: ReviewNavigationState
    ) -> ReviewNavigationState? {
        guard let target = forwardStack.popLast() else {
            return nil
        }
        Self.append(
            current,
            to: &backStack,
            maximumEntryCount: maximumEntryCount
        )
        return target
    }

    mutating func removeAll() {
        backStack = []
        forwardStack = []
    }

    private static func append(
        _ state: ReviewNavigationState,
        to stack: inout [ReviewNavigationState],
        maximumEntryCount: Int
    ) {
        guard maximumEntryCount > 0 else {
            return
        }
        stack.append(state)
        if stack.count > maximumEntryCount {
            stack.removeFirst(stack.count - maximumEntryCount)
        }
    }
}

@discardableResult
func invalidateReviewedSnapshots(
    in state: inout ReviewState,
    currentByFileID: [String: DiffReviewSnapshotID]
) -> Bool {
    let previous = state.reviewedSnapshotByFileID
    state.reviewedSnapshotByFileID = previous.filter { fileID, snapshotID in
        currentByFileID[fileID] == snapshotID
    }
    return state.reviewedSnapshotByFileID != previous
}

@discardableResult
func synchronizeReviewFileExpansion(
    in state: inout ReviewState,
    fileIDs: Set<String>
) -> Bool {
    let previousCollapsed = state.collapsedFileIDs
    let previousKnown = state.knownFileIDs
    let newFileIDs = fileIDs.subtracting(state.knownFileIDs)
    state.collapsedFileIDs.formUnion(newFileIDs)
    state.collapsedFileIDs.formIntersection(fileIDs)
    state.knownFileIDs = fileIDs
    return state.collapsedFileIDs != previousCollapsed
        || state.knownFileIDs != previousKnown
}

func isReviewFileExpanded(
    _ fileID: String,
    in state: ReviewState
) -> Bool {
    state.knownFileIDs.contains(fileID)
        && !state.collapsedFileIDs.contains(fileID)
}

@discardableResult
func setReviewFileExpansion(
    in state: inout ReviewState,
    fileIDs: Set<String>,
    isExpanded: Bool
) -> Bool {
    let previousCollapsed = state.collapsedFileIDs
    let previousKnown = state.knownFileIDs
    state.knownFileIDs.formUnion(fileIDs)
    if isExpanded {
        state.collapsedFileIDs.subtract(fileIDs)
    } else {
        state.collapsedFileIDs.formUnion(fileIDs)
    }
    return state.collapsedFileIDs != previousCollapsed
        || state.knownFileIDs != previousKnown
}

@discardableResult
func toggleReviewFileExpansion(
    in state: inout ReviewState,
    fileID: String
) -> Bool {
    setReviewFileExpansion(
        in: &state,
        fileIDs: [fileID],
        isExpanded: !isReviewFileExpanded(fileID, in: state)
    )
}

@discardableResult
func synchronizeNavigatorFolderExpansion(
    in state: inout ReviewState,
    validFolderIDs: Set<String>
) -> Bool {
    let previous = state.expandedNavigatorFolderIDs
    state.expandedNavigatorFolderIDs.formIntersection(validFolderIDs)
    return state.expandedNavigatorFolderIDs != previous
}

/// 刻意不做 @Observable：滚动位置每帧都在变，进入观察体系会把整个工作区拖进重绘。
@MainActor
final class ReviewStateStore {
    private static let persistenceKey = "agentgit.review-state.v1"
    private static let persistenceVersion = 1
    private static let maximumEntryCount = 64

    private let defaults: UserDefaults
    private var states: [ReviewStateKey: ReviewState] = [:]
    private var scrollOffsets: [ReviewStateKey: CGFloat] = [:]
    private var updatedAtByKey: [ReviewStateKey: Date] = [:]
    private var lastContextByWorktreeID: [
        GitWorktreeSnapshot.ID: ReviewNavigationState
    ] = [:]
    private var lastContextUpdatedAtByWorktreeID: [GitWorktreeSnapshot.ID: Date] = [:]
    private var persistenceTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restorePersistedState()
    }

    func state(for key: ReviewStateKey) -> ReviewState {
        if states[key] != nil || scrollOffsets[key] != nil {
            updatedAtByKey[key] = Date()
        }
        return states[key] ?? ReviewState()
    }

    func save(_ state: ReviewState, for key: ReviewStateKey) {
        states[key] = state
        updatedAtByKey[key] = Date()
        schedulePersistence()
    }

    func lastContext(
        for worktreeID: GitWorktreeSnapshot.ID
    ) -> ReviewNavigationState {
        lastContextByWorktreeID[worktreeID] ?? .pending
    }

    func saveLastContext(
        _ context: ReviewContext,
        selectedCommitIDs: Set<GitCommit.ID>,
        pane: ReviewPane,
        historyFilter: String = "",
        for worktreeID: GitWorktreeSnapshot.ID
    ) {
        let state = ReviewNavigationState(
            context: context,
            selectedCommitIDs: selectedCommitIDs,
            pane: pane,
            historyFilter: historyFilter
        )
        guard lastContextByWorktreeID[worktreeID] != state else {
            return
        }
        lastContextByWorktreeID[worktreeID] = state
        lastContextUpdatedAtByWorktreeID[worktreeID] = Date()
        schedulePersistence()
    }

    func scrollOffset(for key: ReviewStateKey) -> CGFloat {
        scrollOffsets[key] ?? 0
    }

    func saveScrollOffset(_ offset: CGFloat, for key: ReviewStateKey) {
        guard offset.isFinite else {
            return
        }
        let normalizedOffset = max(0, offset)
        if let current = scrollOffsets[key], abs(current - normalizedOffset) < 0.5 {
            return
        }
        scrollOffsets[key] = normalizedOffset
        updatedAtByKey[key] = Date()
        schedulePersistence()
    }

    func flush() {
        persistenceTask?.cancel()
        persistenceTask = nil
        persistNow()
    }

    private func schedulePersistence() {
        guard persistenceTask == nil else {
            return
        }
        persistenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            persistenceTask = nil
            persistNow()
        }
    }

    private func restorePersistedState() {
        guard let data = defaults.data(forKey: Self.persistenceKey) else {
            return
        }
        guard let persisted = try? JSONDecoder().decode(
            PersistedReviewStateStore.self,
            from: data
        ), persisted.version == Self.persistenceVersion else {
            defaults.removeObject(forKey: Self.persistenceKey)
            return
        }
        for entry in persisted.entries.sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(Self.maximumEntryCount) {
            guard states[entry.key] == nil else {
                continue
            }
            states[entry.key] = entry.state.reviewState
            scrollOffsets[entry.key] = max(0, CGFloat(entry.scrollOffset))
            updatedAtByKey[entry.key] = entry.updatedAt
        }
        for entry in persisted.lastContexts.sorted(by: {
            $0.updatedAt > $1.updatedAt
        }).prefix(Self.maximumEntryCount) {
            guard lastContextByWorktreeID[entry.worktreeID] == nil else {
                continue
            }
            lastContextByWorktreeID[entry.worktreeID] = entry.state
            lastContextUpdatedAtByWorktreeID[entry.worktreeID] = entry.updatedAt
        }
    }

    private func persistNow() {
        let keys = Set(states.keys).union(scrollOffsets.keys)
        guard !keys.isEmpty || !lastContextByWorktreeID.isEmpty else {
            defaults.removeObject(forKey: Self.persistenceKey)
            return
        }
        let retainedKeys = keys.sorted {
            (updatedAtByKey[$0] ?? .distantPast) > (updatedAtByKey[$1] ?? .distantPast)
        }.prefix(Self.maximumEntryCount)
        let retainedKeySet = Set(retainedKeys)
        states = states.filter { retainedKeySet.contains($0.key) }
        scrollOffsets = scrollOffsets.filter { retainedKeySet.contains($0.key) }
        updatedAtByKey = updatedAtByKey.filter { retainedKeySet.contains($0.key) }
        let entries = retainedKeys.map { key in
            PersistedReviewStateEntry(
                key: key,
                state: PersistedReviewState(states[key] ?? ReviewState()),
                scrollOffset: Double(scrollOffsets[key] ?? 0),
                updatedAt: updatedAtByKey[key] ?? Date()
            )
        }
        let retainedContextWorktreeIDs = lastContextByWorktreeID.keys.sorted {
            (lastContextUpdatedAtByWorktreeID[$0] ?? .distantPast)
                > (lastContextUpdatedAtByWorktreeID[$1] ?? .distantPast)
        }.prefix(Self.maximumEntryCount)
        let retainedContextWorktreeIDSet = Set(retainedContextWorktreeIDs)
        lastContextByWorktreeID = lastContextByWorktreeID.filter {
            retainedContextWorktreeIDSet.contains($0.key)
        }
        lastContextUpdatedAtByWorktreeID =
            lastContextUpdatedAtByWorktreeID.filter {
                retainedContextWorktreeIDSet.contains($0.key)
            }
        let lastContexts = retainedContextWorktreeIDs.compactMap { worktreeID in
            lastContextByWorktreeID[worktreeID].map { state in
                PersistedLastReviewContext(
                    worktreeID: worktreeID,
                    state: state,
                    updatedAt: lastContextUpdatedAtByWorktreeID[worktreeID]
                        ?? Date()
                )
            }
        }
        let value = PersistedReviewStateStore(
            version: Self.persistenceVersion,
            entries: entries,
            lastContexts: lastContexts
        )
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        defaults.set(data, forKey: Self.persistenceKey)
    }
}

private struct PersistedReviewStateStore: Codable {
    let version: Int
    let entries: [PersistedReviewStateEntry]
    let lastContexts: [PersistedLastReviewContext]

    private enum CodingKeys: String, CodingKey {
        case version
        case entries
        case lastContexts
    }

    init(
        version: Int,
        entries: [PersistedReviewStateEntry],
        lastContexts: [PersistedLastReviewContext]
    ) {
        self.version = version
        self.entries = entries
        self.lastContexts = lastContexts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        entries = try container.decode(
            [PersistedReviewStateEntry].self,
            forKey: .entries
        )
        lastContexts = try container.decodeIfPresent(
            [PersistedLastReviewContext].self,
            forKey: .lastContexts
        ) ?? []
    }
}

private struct PersistedLastReviewContext: Codable {
    let worktreeID: GitWorktreeSnapshot.ID
    let state: ReviewNavigationState
    let updatedAt: Date
}

private struct PersistedReviewStateEntry: Codable {
    let key: ReviewStateKey
    let state: PersistedReviewState
    let scrollOffset: Double
    let updatedAt: Date
}

private struct PersistedReviewState: Codable {
    let collapsedFileIDs: Set<String>
    let knownFileIDs: Set<String>
    let expandedNavigatorFolderIDs: Set<String>
    let focusedFileID: String?
    let reviewedSnapshotByFileID: [String: DiffReviewSnapshotID]
    let wholeFileIDs: Set<String>
    let revealedContextLineCountByGapID: [String: Int]

    init(_ state: ReviewState) {
        collapsedFileIDs = state.collapsedFileIDs
        knownFileIDs = state.knownFileIDs
        expandedNavigatorFolderIDs = state.expandedNavigatorFolderIDs
        focusedFileID = state.focusedFileID
        reviewedSnapshotByFileID = state.reviewedSnapshotByFileID
        wholeFileIDs = state.wholeFileIDs
        revealedContextLineCountByGapID = state.revealedContextLineCountByGapID
    }

    var reviewState: ReviewState {
        ReviewState(
            collapsedFileIDs: collapsedFileIDs,
            knownFileIDs: knownFileIDs,
            expandedNavigatorFolderIDs: expandedNavigatorFolderIDs,
            focusedFileID: focusedFileID,
            filterText: "",
            reviewedSnapshotByFileID: reviewedSnapshotByFileID,
            wholeFileIDs: wholeFileIDs,
            revealedContextLineCountByGapID: revealedContextLineCountByGapID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case collapsedFileIDs
        case knownFileIDs
        case expandedNavigatorFolderIDs
        case focusedFileID
        case reviewedSnapshotByFileID
        case wholeFileIDs
        case revealedContextLineCountByGapID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collapsedFileIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .collapsedFileIDs
        ) ?? []
        knownFileIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .knownFileIDs
        ) ?? []
        expandedNavigatorFolderIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .expandedNavigatorFolderIDs
        ) ?? []
        focusedFileID = try container.decodeIfPresent(
            String.self,
            forKey: .focusedFileID
        )
        reviewedSnapshotByFileID = try container.decodeIfPresent(
            [String: DiffReviewSnapshotID].self,
            forKey: .reviewedSnapshotByFileID
        ) ?? [:]
        wholeFileIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .wholeFileIDs
        ) ?? []
        revealedContextLineCountByGapID = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .revealedContextLineCountByGapID
        ) ?? [:]
    }
}
