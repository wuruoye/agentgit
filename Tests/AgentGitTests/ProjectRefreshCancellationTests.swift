@testable import AgentGitApp
import AgentGitCore
import Foundation
import Testing

private let project = GitProject(rootURL: URL(fileURLWithPath: "/tmp/agentgit-refresh-tests/repo"))

private func worktree(_ name: String) -> GitWorktree {
    GitWorktree(
        rootURL: project.rootURL.appending(path: name),
        headOID: "a8d99b5c0000000000000000000000000000000",
        branchRef: "refs/heads/\(name)",
        isBare: false,
        isDetached: false,
        lockedReason: nil,
        prunableReason: nil
    )
}

private func snapshot(_ worktree: GitWorktree, activity: TimeInterval) -> GitWorktreeSnapshot {
    GitWorktreeSnapshot(
        worktree: worktree,
        status: .clean,
        diffStat: .zero,
        lastActivityAt: Date(timeIntervalSince1970: activity),
        errorMessage: nil
    )
}

@MainActor
@Test func cancelledProjectRefreshDoesNotReturnPartialSnapshot() async {
    let events = AsyncThrowingStream<GitProjectRefreshEvent, any Error>.makeStream()
    let main = worktree("main")
    let feature = worktree("feature")
    events.continuation.yield(.discovered(project: project, worktrees: [main, feature]))
    events.continuation.yield(.worktree(snapshot(main, activity: 10)))

    let received = AsyncStream<Void>.makeStream()
    let refresh = Task { @MainActor in
        try await collectProjectRefresh(
            events.stream,
            project: project,
            onDiscovered: { _, _ in },
            onWorktree: { _, _ in received.continuation.yield() }
        )
    }
    var iterator = received.stream.makeAsyncIterator()
    _ = await iterator.next()

    // 第二个 worktree 还没到时外层任务被取消：事件流直接结束，不能把只含 main 的结果当成完整刷新。
    refresh.cancel()
    await #expect(throws: CancellationError.self) {
        try await refresh.value
    }
}

@MainActor
@Test func completedProjectRefreshCollectsEveryWorktree() async throws {
    let events = AsyncThrowingStream<GitProjectRefreshEvent, any Error>.makeStream()
    let renamedProject = GitProject(rootURL: project.rootURL)
    let main = worktree("main")
    let feature = worktree("feature")
    events.continuation.yield(.discovered(project: renamedProject, worktrees: [main, feature]))
    events.continuation.yield(.worktree(snapshot(main, activity: 10)))
    events.continuation.yield(.worktree(snapshot(feature, activity: 20)))
    events.continuation.finish()

    var discovered: [GitWorktree] = []
    var partialProjects: [GitProject] = []
    let result = try await collectProjectRefresh(
        events.stream,
        project: project,
        onDiscovered: { _, worktrees in discovered = worktrees },
        onWorktree: { project, _ in partialProjects.append(project) }
    )

    #expect(discovered == [main, feature])
    #expect(partialProjects == [renamedProject, renamedProject])
    #expect(result.project == renamedProject)
    // 按最近活动排序，新的在前。
    #expect(result.worktrees.map(\.id) == [feature.id, main.id])
}

@MainActor
@Test func failedProjectRefreshRethrows() async {
    struct ListFailure: Error {}
    let events = AsyncThrowingStream<GitProjectRefreshEvent, any Error>.makeStream()
    events.continuation.finish(throwing: ListFailure())
    await #expect(throws: ListFailure.self) {
        try await collectProjectRefresh(
            events.stream,
            project: project,
            onDiscovered: { _, _ in },
            onWorktree: { _, _ in }
        )
    }
}

@Test func cachedEmptyProjectSnapshotIsNotTrustedAsComplete() {
    let other = GitProject(rootURL: URL(fileURLWithPath: "/tmp/agentgit-refresh-tests/other"))
    let cached = [
        GitProjectSnapshot(project: project, worktrees: [], refreshedAt: Date()),
        GitProjectSnapshot(
            project: other,
            worktrees: [snapshot(worktree("main"), activity: 10)],
            refreshedAt: Date()
        )
    ]
    #expect(
        trustedCompleteProjectIDs([project.id, other.id], cachedProjects: cached) == [other.id]
    )
    // 没有缓存快照的项目保持原样，由缺失快照的刷新负责。
    #expect(trustedCompleteProjectIDs(["/tmp/missing"], cachedProjects: cached) == ["/tmp/missing"])
}
