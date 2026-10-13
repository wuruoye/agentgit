import AgentGitCore
import CoreServices
import Foundation

struct RepositoryChangeImpact: Equatable, Sendable {
    var projectIDs: Set<GitProject.ID> = []
    var metadataWorktreeIDs: Set<GitWorktree.ID> = []
    var contentPathsByWorktreeID: [GitWorktree.ID: Set<String>] = [:]

    var worktreeIDs: Set<GitWorktree.ID> {
        metadataWorktreeIDs.union(contentPathsByWorktreeID.keys)
    }

    var isEmpty: Bool {
        projectIDs.isEmpty && worktreeIDs.isEmpty
    }

    mutating func addContentPath(
        _ path: String,
        worktreeIDs: Set<GitWorktree.ID>
    ) {
        for worktreeID in worktreeIDs {
            contentPathsByWorktreeID[worktreeID, default: []].insert(path)
        }
    }

    mutating func formUnion(_ other: Self) {
        projectIDs.formUnion(other.projectIDs)
        metadataWorktreeIDs.formUnion(other.metadataWorktreeIDs)
        for (id, paths) in other.contentPathsByWorktreeID {
            contentPathsByWorktreeID[id, default: []].formUnion(paths)
        }
    }
}

struct RepositoryWatchIndex: Sendable {
    private struct Entry: Sendable {
        let path: String
        let worktreeIDs: Set<GitWorktree.ID>
        let isWorktreeRoot: Bool
    }

    private struct CommonMetadataEntry: Sendable {
        let path: String
        let projectIDs: Set<GitProject.ID>
    }

    private let entries: [Entry]
    private let gitMetadataPaths: [String]
    private let primaryWorktreeIDBySharedMetadataPath: [String: GitWorktree.ID]
    private let commonMetadataEntries: [CommonMetadataEntry]
    private let knownWorktreeMetadataPaths: Set<String>
    private let worktreeIDsByRefMetadataPath: [String: Set<GitWorktree.ID>]
    private let projectIDs: Set<GitProject.ID>

    init(projects: [ProjectState]) {
        var IDsByPath: [String: Set<GitWorktree.ID>] = [:]
        var worktreeRootPaths: Set<String> = []
        var primaryWorktreeCandidates: [String: GitWorktree.ID] = [:]
        var projectIDsByCommonMetadataPath: [String: Set<GitProject.ID>] = [:]
        var worktreeIDsByReferencePath: [String: Set<GitWorktree.ID>] = [:]
        var allKnownWorktreeMetadataPaths: Set<String> = []
        var loadedProjectIDs: Set<GitProject.ID> = []
        for project in projects {
            guard let snapshot = project.snapshot else {
                continue
            }
            loadedProjectIDs.insert(project.id)
            var metadataPathsByWorktree: [Set<String>] = []
            for worktree in snapshot.worktrees {
                let rootPath = worktree.worktree.rootURL.standardizedFileURL.path
                worktreeRootPaths.insert(rootPath)
                let watchURLs = worktree.eventWatchURLs.isEmpty
                    ? [worktree.worktree.rootURL]
                    : worktree.eventWatchURLs
                var metadataPaths: Set<String> = []
                for url in watchURLs {
                    let watchPath = url.standardizedFileURL.path
                    IDsByPath[watchPath, default: []].insert(worktree.id)
                    if watchPath != rootPath {
                        metadataPaths.insert(watchPath)
                    }
                    if watchPath == rootPath + "/.git" {
                        primaryWorktreeCandidates[watchPath] = worktree.id
                    }
                }
                if !metadataPaths.isEmpty { metadataPathsByWorktree.append(metadataPaths) }
            }
            if var sharedMetadataPaths = metadataPathsByWorktree.first {
                for metadataPaths in metadataPathsByWorktree.dropFirst() {
                    sharedMetadataPaths.formIntersection(metadataPaths)
                }
                for path in sharedMetadataPaths {
                    projectIDsByCommonMetadataPath[path, default: []].insert(project.id)
                    for worktree in snapshot.worktrees {
                        var referencePaths: [String] = []
                        if let branchRef = worktree.worktree.branchRef {
                            referencePaths.append(branchRef)
                        }
                        if let upstreamRef = worktree.status.branch?.upstreamRef {
                            referencePaths.append(
                                upstreamRef.hasPrefix("refs/")
                                    ? upstreamRef
                                    : "refs/remotes/\(upstreamRef)"
                            )
                        }
                        for referencePath in referencePaths {
                            worktreeIDsByReferencePath[
                                path + "/" + referencePath,
                                default: []
                            ].insert(worktree.id)
                            worktreeIDsByReferencePath[
                                path + "/logs/" + referencePath,
                                default: []
                            ].insert(worktree.id)
                        }
                    }
                }
                let allMetadataPaths = metadataPathsByWorktree.reduce(into: Set<String>()) {
                    $0.formUnion($1)
                }
                allKnownWorktreeMetadataPaths.formUnion(
                    allMetadataPaths.subtracting(sharedMetadataPaths)
                )
            }
        }
        gitMetadataPaths = projects.flatMap { project in
            project.snapshot?.worktrees.flatMap { worktree in
                worktree.eventWatchURLs.filter {
                    $0.standardizedFileURL.path
                        != worktree.worktree.rootURL.standardizedFileURL.path
                }.map { $0.standardizedFileURL.path }
            } ?? []
        }.uniqued().sorted { $0.count > $1.count }
        entries = IDsByPath.map { path, worktreeIDs in
            Entry(
                path: path,
                worktreeIDs: worktreeIDs,
                isWorktreeRoot: worktreeRootPaths.contains(path)
            )
        }.sorted { lhs, rhs in
            if lhs.path.count != rhs.path.count {
                return lhs.path.count > rhs.path.count
            }
            return lhs.path < rhs.path
        }
        primaryWorktreeIDBySharedMetadataPath = primaryWorktreeCandidates.filter {
            (IDsByPath[$0.key]?.count ?? 0) > 1
        }
        commonMetadataEntries = projectIDsByCommonMetadataPath.map { path, projectIDs in
            CommonMetadataEntry(path: path, projectIDs: projectIDs)
        }.sorted { $0.path.count > $1.path.count }
        knownWorktreeMetadataPaths = allKnownWorktreeMetadataPaths
        worktreeIDsByRefMetadataPath = worktreeIDsByReferencePath
        projectIDs = loadedProjectIDs
    }

    var watchedPaths: [String] {
        entries.map(\.path)
    }

    var allWorktreeIDs: Set<GitWorktree.ID> {
        entries.reduce(into: []) { result, entry in
            result.formUnion(entry.worktreeIDs)
        }
    }

    func worktreeIDs(watching paths: Set<String>) -> Set<GitWorktree.ID> {
        entries.reduce(into: []) { result, entry in
            if paths.contains(entry.path) { result.formUnion(entry.worktreeIDs) }
        }
    }

    var fullRefreshImpact: RepositoryChangeImpact {
        RepositoryChangeImpact(
            projectIDs: projectIDs,
            metadataWorktreeIDs: allWorktreeIDs
        )
    }

    func impact(for eventPaths: [String]) -> RepositoryChangeImpact {
        var impact = RepositoryChangeImpact()
        for eventPath in eventPaths {
            let path = URL(fileURLWithPath: eventPath).standardizedFileURL.path
            if isGitMaintenancePath(path) {
                continue
            }
            let referencePath = path.hasSuffix(".lock")
                ? String(path.dropLast(".lock".count))
                : path
            if let worktreeIDs = worktreeIDsByRefMetadataPath[referencePath] {
                impact.metadataWorktreeIDs.formUnion(worktreeIDs)
                continue
            }
            let membershipProjectIDs = projectIDsForWorktreeMembershipEvent(path)
            if !membershipProjectIDs.isEmpty {
                impact.projectIDs.formUnion(membershipProjectIDs)
                continue
            }
            if let entry = entries.first(where: {
                path == $0.path || path.hasPrefix($0.path + "/")
            }) {
                let relativePath = path == entry.path
                    ? ""
                    : String(path.dropFirst(entry.path.count + 1))
                if entry.isWorktreeRoot {
                    impact.addContentPath(
                        path,
                        worktreeIDs: entry.worktreeIDs
                    )
                } else if let primaryWorktreeID =
                    primaryWorktreeIDBySharedMetadataPath[entry.path],
                   isPrimaryWorktreeMetadataPath(relativePath) {
                    impact.metadataWorktreeIDs.insert(primaryWorktreeID)
                } else {
                    impact.metadataWorktreeIDs.formUnion(entry.worktreeIDs)
                }
            }
        }
        return impact
    }

    private func projectIDsForWorktreeMembershipEvent(
        _ path: String
    ) -> Set<GitProject.ID> {
        guard let commonMetadata = commonMetadataEntries.first(where: {
            path == $0.path || path.hasPrefix($0.path + "/")
        }) else {
            return []
        }
        let relativePath = path == commonMetadata.path
            ? ""
            : String(path.dropFirst(commonMetadata.path.count + 1))
        guard relativePath == "worktrees" || relativePath.hasPrefix("worktrees/") else {
            return []
        }
        guard relativePath != "worktrees" else {
            return commonMetadata.projectIDs
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            return commonMetadata.projectIDs
        }
        let adminPath = commonMetadata.path + "/worktrees/" + String(components[1])
        guard knownWorktreeMetadataPaths.contains(adminPath) else {
            return commonMetadata.projectIDs
        }
        guard components.count == 2 else {
            let metadataName = String(components[2])
            return ["gitdir", "commondir", "locked", "prunable"].contains(metadataName)
                ? commonMetadata.projectIDs
                : []
        }
        return commonMetadata.projectIDs
    }

    private func isGitMaintenancePath(_ path: String) -> Bool {
        gitMetadataPaths.contains { gitPath in
            guard path.hasPrefix(gitPath + "/") else {
                return false
            }
            let relativePath = String(path.dropFirst(gitPath.count + 1))
            return relativePath == "FETCH_HEAD"
                || relativePath == "FETCH_HEAD.lock"
                || relativePath == "fsmonitor--daemon"
                || relativePath.hasPrefix("fsmonitor--daemon/")
                || relativePath == "objects"
                || relativePath.hasPrefix("objects/")
        }
    }

    private func isPrimaryWorktreeMetadataPath(_ relativePath: String) -> Bool {
        if [
            "HEAD",
            "index",
            "index.lock",
            "ORIG_HEAD",
            "MERGE_HEAD",
            "REBASE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "AUTO_MERGE",
            "SQUASH_MSG",
            "COMMIT_EDITMSG",
            "config.worktree"
        ].contains(relativePath) {
            return true
        }
        return relativePath == "logs/HEAD"
            || relativePath.hasPrefix("logs/HEAD.")
            || relativePath == "rebase-apply"
            || relativePath.hasPrefix("rebase-apply/")
            || relativePath == "rebase-merge"
            || relativePath.hasPrefix("rebase-merge/")
            || relativePath == "sequencer"
            || relativePath.hasPrefix("sequencer/")
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

enum RepositoryFileMonitorError: LocalizedError {
    case streamCreationFailed
    case streamStartFailed

    var errorDescription: String? {
        switch self {
        case .streamCreationFailed: "Unable to create the repository FSEvents stream."
        case .streamStartFailed: "Unable to start the repository FSEvents stream."
        }
    }
}

final class RepositoryFileMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (
        RepositoryChangeImpact,
        FSEventStreamEventId
    ) -> Void

    private let queue = DispatchQueue(label: "com.sigma.agentgit.repository-events")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let handler: Handler
    private let cursor: RepositoryEventCursor
    private var stream: FSEventStreamRef?
    private var callbackBox: Unmanaged<RepositoryEventCallbackBox>?
    private var watchedPaths: [String] = []

    init(
        sinceWhen: FSEventStreamEventId = FSEventsGetCurrentEventId(),
        handler: @escaping Handler
    ) {
        self.cursor = RepositoryEventCursor(sinceWhen: sinceWhen)
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    func update(index: RepositoryWatchIndex, acknowledgedEventID: FSEventStreamEventId) throws {
        let nextWatchedPaths = index.watchedPaths
        if stream != nil,
           nextWatchedPaths == watchedPaths,
           let callbackBox {
            callbackBox.takeUnretainedValue().update(index: index)
            return
        }
        stop()
        cursor.restart(from: acknowledgedEventID)
        guard !nextWatchedPaths.isEmpty else {
            return
        }
        let box = Unmanaged.passRetained(
            RepositoryEventCallbackBox(
                index: index,
                cursor: cursor,
                handler: handler
            )
        )
        var context = FSEventStreamContext(
            version: 0,
            info: box.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            repositoryEventCallback,
            &context,
            nextWatchedPaths as CFArray,
            cursor.sinceWhen,
            0.25,
            flags
        ) else {
            box.release()
            throw RepositoryFileMonitorError.streamCreationFailed
        }
        FSEventStreamSetDispatchQueue(createdStream, queue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            box.release()
            throw RepositoryFileMonitorError.streamStartFailed
        }
        callbackBox = box
        stream = createdStream
        watchedPaths = nextWatchedPaths
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        callbackBox?.release()
        callbackBox = nil
        watchedPaths = []
    }
}

private final class RepositoryEventCursor: @unchecked Sendable {
    private let lock = NSLock()
    private var latestEventID: FSEventStreamEventId

    init(sinceWhen: FSEventStreamEventId) {
        self.latestEventID = sinceWhen
    }

    var sinceWhen: FSEventStreamEventId {
        lock.withLock { latestEventID }
    }

    func advance(to eventID: FSEventStreamEventId) {
        lock.withLock {
            latestEventID = max(latestEventID, eventID)
        }
    }

    func restart(from eventID: FSEventStreamEventId) {
        lock.withLock { latestEventID = eventID }
    }
}

private final class RepositoryEventCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var index: RepositoryWatchIndex
    let cursor: RepositoryEventCursor
    let handler: RepositoryFileMonitor.Handler

    init(
        index: RepositoryWatchIndex,
        cursor: RepositoryEventCursor,
        handler: @escaping RepositoryFileMonitor.Handler
    ) {
        self.index = index
        self.cursor = cursor
        self.handler = handler
    }

    func update(index: RepositoryWatchIndex) {
        lock.withLock {
            self.index = index
        }
    }

    func currentIndex() -> RepositoryWatchIndex {
        lock.withLock { index }
    }
}

struct RepositoryEventBatch: Sendable {
    let paths: [String]
    let flags: [FSEventStreamEventFlags]

    func impact(using index: RepositoryWatchIndex) -> RepositoryChangeImpact {
        let historyDoneFlag = FSEventStreamEventFlags(
            kFSEventStreamEventFlagHistoryDone
        )
        let relevant = zip(paths, flags).filter { _, flags in
            flags & historyDoneFlag == 0
        }
        let fullRefreshFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        if relevant.contains(where: { _, flags in
            flags & fullRefreshFlags != 0
        }) {
            return index.fullRefreshImpact
        }
        return index.impact(for: relevant.map(\.0))
    }
}

private let repositoryEventCallback: FSEventStreamCallback = {
    _, callbackInfo, eventCount, eventPaths, eventFlags, eventIDs in
    guard let callbackInfo else {
        return
    }
    let box = Unmanaged<RepositoryEventCallbackBox>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    let boundedPaths = Array(paths.prefix(Int(eventCount)))
    let IDs = UnsafeBufferPointer(start: eventIDs, count: Int(eventCount))
    let latestEventID = IDs.max() ?? box.cursor.sinceWhen
    box.cursor.advance(to: latestEventID)
    let flags = UnsafeBufferPointer(start: eventFlags, count: Int(eventCount))
    let index = box.currentIndex()
    let impact = RepositoryEventBatch(
        paths: boundedPaths,
        flags: Array(flags)
    ).impact(using: index)
    box.handler(impact, latestEventID)
}
