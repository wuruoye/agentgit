import AgentGitCore
import Foundation

/// 侧栏 worktree 行要回答的问题是「这几十个 worktree 里，哪个现在轮到我」。
/// 全部由已有的 `status` 和 `diffStat` 推出，不额外跑 git 命令。
///
/// 刻意不提供「可以删了」这一档：判断一个分支是否已经合入上游需要额外的 merge-base
/// 查询，现在拿不到，猜出来的结论会让人误删。
enum WorktreeReviewStatus: Equatable {
    /// 仓库读不出来。
    case unavailable
    /// 有未提交的改动，通常是 agent 刚写完还没提交。
    case needsReview
    /// 本地领先上游，提交了还没推。
    case ahead(Int)
    /// 上游领先本地，需要拉。
    case behind(Int)
    /// 两边都有对方没有的提交。
    case diverged(ahead: Int, behind: Int)
    /// 有上游且完全同步，本地也没有改动。
    case synced
    /// 没有配置上游，只有本地历史。
    case local
}

func worktreeReviewStatus(_ snapshot: GitWorktreeSnapshot) -> WorktreeReviewStatus {
    if snapshot.errorMessage != nil, !snapshot.hasUsableState {
        return .unavailable
    }
    if snapshot.status.changedFileCount > 0 || !snapshot.diffStat.isEmpty {
        return .needsReview
    }
    guard let branch = snapshot.status.branch,
          let upstreamRef = branch.upstreamRef,
          !upstreamRef.isEmpty else {
        return .local
    }
    switch (branch.aheadCount, branch.behindCount) {
    case let (ahead, behind) where ahead > 0 && behind > 0:
        return .diverged(ahead: ahead, behind: behind)
    case let (ahead, 0) where ahead > 0:
        return .ahead(ahead)
    case let (0, behind) where behind > 0:
        return .behind(behind)
    default:
        return .synced
    }
}

extension WorktreeReviewStatus {
    /// 行尾那一小块位置只够放几个字符，所以领先落后用 `↑` `↓` 加数字表示。
    /// 有未提交改动时这里让位给 `+N −M`，那个更紧急也更具体。
    var compactIndicator: String? {
        switch self {
        case .unavailable, .needsReview, .synced, .local:
            nil
        case let .ahead(count):
            "↑\(count)"
        case let .behind(count):
            "↓\(count)"
        case let .diverged(ahead, behind):
            "↑\(ahead) ↓\(behind)"
        }
    }

    /// 读屏和 tooltip 用的完整说法。
    var accessibilityDescription: String {
        switch self {
        case .unavailable:
            "Repository unavailable"
        case .needsReview:
            "Uncommitted changes"
        case let .ahead(count):
            countedLabel(count, singular: "commit") + " to push"
        case let .behind(count):
            countedLabel(count, singular: "commit") + " to pull"
        case let .diverged(ahead, behind):
            countedLabel(ahead, singular: "commit") + " to push, "
                + countedLabel(behind, singular: "commit") + " to pull"
        case .synced:
            "Up to date"
        case .local:
            "Local only"
        }
    }

    /// 是否需要用户做点什么。侧栏的「只看待办」筛选按这个判定。
    var needsAttention: Bool {
        switch self {
        case .unavailable, .needsReview, .ahead, .behind, .diverged:
            true
        case .synced, .local:
            false
        }
    }
}
