import AgentGitCore
@testable import AgentGitApp
import Foundation
import Testing

@Test func sidebarKeepsActiveWorktreesAndAtLeastOnePerRepository() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func worktree(_ name: String, age: TimeInterval, changed: Bool = false) -> GitWorktreeSnapshot {
        GitWorktreeSnapshot(
            worktree: GitWorktree(
                rootURL: URL(fileURLWithPath: "/repos/example/\(name)"),
                headOID: "1234567", branchRef: "refs/heads/\(name)",
                isBare: false, isDetached: false, lockedReason: nil, prunableReason: nil
            ),
            status: changed ? GitStatusSnapshot(changes: [GitFileChange(
                path: "file.swift", originalPath: nil,
                indexStatus: ".", worktreeStatus: "M", kind: .ordinary
            )]) : .clean,
            diffStat: .zero, lastActivityAt: now.addingTimeInterval(-age), errorMessage: nil
        )
    }
    let changed = (0..<7).map { worktree("changed-\($0)", age: Double(7_200 + $0), changed: true) }
    let lastHour = (0..<7).map { worktree("last-hour-\($0)", age: Double(3_600 - $0)) }
    let recent = (0..<5).map { worktree("recent-\($0)", age: Double(3_601 + $0)) }
    let pinned = worktree("pinned", age: 172_800)
    let selected = worktree("selected", age: 172_801)
    let stale = worktree("stale", age: 172_802)
    let snapshot = GitProjectSnapshot(
        project: GitProject(rootURL: URL(fileURLWithPath: "/repos/example")),
        worktrees: [stale, selected, pinned] + recent.reversed() + lastHour + changed.reversed(),
        refreshedAt: now
    )
    let presentation = projectWorktreePresentation(
        snapshot: snapshot, selectedWorktreeID: selected.id,
        pinnedWorktreeIDs: [pinned.id], showsAll: false, now: now
    )
    #expect(presentation.visibleWorktrees.map(\.id)
        == ([pinned] + lastHour.reversed() + changed + [selected]).map(\.id))
    #expect(presentation.hiddenWorktreeCount == 6)

    let inactiveSnapshot = GitProjectSnapshot(
        project: snapshot.project, worktrees: [stale, selected, pinned], refreshedAt: now
    )
    let inactive = projectWorktreePresentation(
        snapshot: inactiveSnapshot, selectedWorktreeID: nil, showsAll: false, now: now
    )
    #expect(inactive.visibleWorktrees.map(\.id) == [pinned.id])
    #expect(inactive.hiddenWorktreeCount == 2)

    let all = projectWorktreePresentation(
        snapshot: snapshot, selectedWorktreeID: selected.id,
        pinnedWorktreeIDs: [pinned.id], showsAll: true, now: now
    )
    #expect(all.visibleWorktrees.count == snapshot.worktrees.count)
    #expect(all.visibleWorktrees.first?.id == pinned.id)
}
