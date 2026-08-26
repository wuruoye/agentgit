import AgentGitCore
import Foundation

/// 一次 Review 的上下文。Pending、单 commit、commit range 共用同一套状态与同一个 Review 流。
enum ReviewContext: Hashable {
    case pending
    case commit(GitCommit.ID)
    case range(base: GitCommit.ID, head: GitCommit.ID)
}

enum ReviewPane: String, Hashable, CaseIterable, Identifiable {
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
struct ReviewState {
    var collapsedFileIDs: Set<String> = []
    var focusedFileID: String?
    var filterText = ""
    var isFocusedOnly = false
}

struct ReviewStateKey: Hashable {
    let worktreeID: GitWorktreeSnapshot.ID
    let context: ReviewContext
}

/// 刻意不做 @Observable：滚动位置每帧都在变，进入观察体系会把整个工作区拖进重绘。
@MainActor
final class ReviewStateStore {
    private var states: [ReviewStateKey: ReviewState] = [:]
    private var scrollOffsets: [ReviewStateKey: CGFloat] = [:]

    func state(for key: ReviewStateKey) -> ReviewState {
        states[key] ?? ReviewState()
    }

    func save(_ state: ReviewState, for key: ReviewStateKey) {
        states[key] = state
    }

    func scrollOffset(for key: ReviewStateKey) -> CGFloat {
        scrollOffsets[key] ?? 0
    }

    func saveScrollOffset(_ offset: CGFloat, for key: ReviewStateKey) {
        scrollOffsets[key] = offset
    }
}
