import AgentGitCore
import XCTest

@testable import AgentGitApp

final class WorktreeReviewStatusTests: XCTestCase {
    func testDerivesStatusFromSnapshot() {
        // 有未提交改动时先报 needsReview：即使同时落后上游，先看的也是本地这堆改动。
        XCTAssertEqual(
            worktreeReviewStatus(
                makeSnapshot(
                    isDirty: true,
                    branch: GitBranchStatus(
                        upstreamRef: "origin/feature",
                        aheadCount: 0,
                        behindCount: 4
                    )
                )
            ),
            .needsReview
        )

        XCTAssertEqual(
            worktreeReviewStatus(
                makeSnapshot(
                    branch: GitBranchStatus(
                        upstreamRef: "origin/feature",
                        aheadCount: 9,
                        behindCount: 0
                    )
                )
            ),
            .ahead(9)
        )

        XCTAssertEqual(
            worktreeReviewStatus(
                makeSnapshot(
                    branch: GitBranchStatus(
                        upstreamRef: "origin/feature",
                        aheadCount: 0,
                        behindCount: 65
                    )
                )
            ),
            .behind(65)
        )

        XCTAssertEqual(
            worktreeReviewStatus(
                makeSnapshot(
                    branch: GitBranchStatus(
                        upstreamRef: "origin/feature",
                        aheadCount: 1,
                        behindCount: 159
                    )
                )
            ),
            .diverged(ahead: 1, behind: 159)
        )

        XCTAssertEqual(
            worktreeReviewStatus(
                makeSnapshot(
                    branch: GitBranchStatus(
                        upstreamRef: "origin/feature",
                        aheadCount: 0,
                        behindCount: 0
                    )
                )
            ),
            .synced
        )

        // 没有上游时不能报 synced：那会让人以为已经推上去了。
        XCTAssertEqual(worktreeReviewStatus(makeSnapshot(branch: nil)), .local)

        XCTAssertEqual(
            worktreeReviewStatus(
                makeSnapshot(errorMessage: "fatal: not a git repository", hasUsableState: false)
            ),
            .unavailable
        )
    }

    func testOnlyActionableStatusesNeedAttention() {
        XCTAssertTrue(WorktreeReviewStatus.needsReview.needsAttention)
        XCTAssertTrue(WorktreeReviewStatus.ahead(1).needsAttention)
        XCTAssertTrue(WorktreeReviewStatus.behind(1).needsAttention)
        XCTAssertTrue(WorktreeReviewStatus.diverged(ahead: 1, behind: 1).needsAttention)
        XCTAssertTrue(WorktreeReviewStatus.unavailable.needsAttention)
        XCTAssertFalse(WorktreeReviewStatus.synced.needsAttention)
        XCTAssertFalse(WorktreeReviewStatus.local.needsAttention)
    }

    func testCompactIndicatorOnlyCoversTrackingCounts() {
        XCTAssertEqual(WorktreeReviewStatus.ahead(9).compactIndicator, "↑9")
        XCTAssertEqual(WorktreeReviewStatus.behind(65).compactIndicator, "↓65")
        XCTAssertEqual(
            WorktreeReviewStatus.diverged(ahead: 1, behind: 159).compactIndicator,
            "↑1 ↓159"
        )
        // 有改动的行让位给 +N −M，同步和纯本地没有可显示的计数。
        XCTAssertNil(WorktreeReviewStatus.needsReview.compactIndicator)
        XCTAssertNil(WorktreeReviewStatus.synced.compactIndicator)
        XCTAssertNil(WorktreeReviewStatus.local.compactIndicator)
    }

    func testRemoteActionTitlesCarryCounts() {
        let diverged = GitBranchStatus(
            upstreamRef: "origin/feature",
            aheadCount: 1,
            behindCount: 159
        )
        XCTAssertEqual(gitPullActionTitle(branchStatus: diverged), "Pull 159")
        XCTAssertEqual(gitPushActionTitle(branchStatus: diverged), "Push 1")

        let synced = GitBranchStatus(
            upstreamRef: "origin/feature",
            aheadCount: 0,
            behindCount: 0
        )
        XCTAssertEqual(gitPullActionTitle(branchStatus: synced), "Pull")
        XCTAssertEqual(gitPushActionTitle(branchStatus: synced), "Push")
        XCTAssertEqual(gitPushActionTitle(branchStatus: nil), "Publish")

        // 没有数字的按钮保持纯图标，工具栏不会被两个常驻标题撑宽。
        XCTAssertFalse(gitRemoteActionShowsTitle("Pull"))
        XCTAssertFalse(gitRemoteActionShowsTitle("Push"))
        XCTAssertTrue(gitRemoteActionShowsTitle("Pull 159"))
        XCTAssertTrue(gitRemoteActionShowsTitle("Publish"))
    }

    private func makeSnapshot(
        isDirty: Bool = false,
        branch: GitBranchStatus? = nil,
        errorMessage: String? = nil,
        hasUsableState: Bool = true
    ) -> GitWorktreeSnapshot {
        let change = GitFileChange(
            path: "Sources/Changed.swift",
            originalPath: nil,
            indexStatus: ".",
            worktreeStatus: "M",
            kind: .ordinary
        )
        return GitWorktreeSnapshot(
            worktree: GitWorktree(
                rootURL: URL(fileURLWithPath: "/worktrees/status"),
                headOID: String(repeating: "b", count: 40),
                branchRef: "refs/heads/feature",
                isBare: false,
                isDetached: false,
                lockedReason: nil,
                prunableReason: nil
            ),
            status: GitStatusSnapshot(
                changes: isDirty ? [change] : [],
                branch: branch
            ),
            diffStat: isDirty
                ? GitDiffStat(addedLineCount: 1, deletedLineCount: 0)
                : .zero,
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            refreshedAt: Date(timeIntervalSince1970: 1_000),
            errorMessage: errorMessage,
            hasUsableState: hasUsableState
        )
    }
}
