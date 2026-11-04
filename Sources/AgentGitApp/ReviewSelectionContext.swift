import AgentGitCore
import AgentGitIntegrationShared
import Foundation

/// diff 视图交给工作区的一段选区：所在文件和按 unified 顺序排好的行。
struct DiffSelectionExcerpt: Equatable {
    let fileID: String
    let lines: [GitDiffLine]
    var includesSelectedCode = true
}

/// 选中代码后可执行的操作。diff 视图只负责显示按钮、回传选区，新操作在工作区里加一项即可。
struct DiffSelectionAction: Identifiable, Equatable {
    struct Choice: Identifiable, Equatable {
        let id: String
        let title: String
    }

    let id: String
    let title: String
    let systemImage: String
    let help: String
    /// 多于一项时点按钮先弹菜单选目标；只有一项时直接用它。
    var choices: [Choice] = []
    var isEnabled = true
}

/// 选区所在的审阅范围。
enum ReviewSelectionScope: Equatable {
    enum PendingSide: Equatable {
        case unstaged
        case staged
        case untracked
    }

    case uncommitted(PendingSide, headOID: String?)
    case commit(oid: String, subject: String?)
    /// base 不含在内，head 含在内，和 `git diff base..head` 一致。
    case range(base: String, head: String)

    var description: String {
        switch self {
        case let .uncommitted(side, headOID):
            let sideTitle = switch side {
            case .unstaged: "unstaged"
            case .staged: "staged"
            case .untracked: "untracked file"
            }
            let head = headOID.map { " on top of HEAD \($0)" } ?? ""
            return "uncommitted changes (\(sideTitle))\(head)"
        case let .commit(oid, subject):
            let trimmed = subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "commit \(oid)" : "commit \(oid) \"\(trimmed)\""
        case let .range(base, head):
            return "commit range \(base)..\(head) (changes after \(base) up to and including \(head))"
        }
    }
}

/// 发给 agent 或复制为引用的上下文：仓库、worktree、文件、行号范围、审阅范围和带 +/- 标记的原文。
struct ReviewSelectionContext: Equatable {
    let repositoryPath: String
    let worktreePath: String
    let branchName: String?
    let scope: ReviewSelectionScope
    let filePath: String
    let originalPath: String?
    let lines: [GitDiffLine]

    var oldLineRange: ClosedRange<Int>? {
        Self.range(of: lines.compactMap(\.oldLineNumber))
    }

    var newLineRange: ClosedRange<Int>? {
        Self.range(of: lines.compactMap(\.newLineNumber))
    }

    /// 例如 `old 120-124, new 120-127`；只有新增行时只写 new。
    var lineRangeDescription: String {
        let parts = [
            oldLineRange.map { "old \(Self.format($0))" },
            newLineRange.map { "new \(Self.format($0))" }
        ].compactMap { $0 }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    var quotedCode: String {
        lines.map(Self.markedText).joined(separator: "\n")
    }

    var text: String {
        let worktree = branchName.map { "\(worktreePath) (branch \($0))" } ?? worktreePath
        let file = originalPath.map { "\(filePath) (renamed from \($0))" } ?? filePath
        let code = quotedCode
        let fence = Self.fence(for: code)
        return """
        Selected code from an AgentGit review:

        - Repository: \(repositoryPath)
        - Worktree: \(worktree)
        - Review scope: \(scope.description)
        - File: \(file)
        - Lines: \(lineRangeDescription)

        \(fence)diff
        \(code)
        \(fence)
        """
    }

    /// 第一行留给用户输入；此处生成最终文本，交付时原样粘贴。
    func agentDraft(includingCode: Bool) -> String {
        var parts = ["", "文件：\(filePath)", "行号：\(lineRangeDescription)"]
        if includingCode, !lines.isEmpty {
            let code = quotedCode
            let fence = Self.fence(for: code)
            parts.append("\(fence)diff\n\(code)\n\(fence)")
        }
        return parts.joined(separator: "\n")
    }

    static func markedText(_ line: GitDiffLine) -> String {
        switch line.kind {
        case .addition: "+" + line.content
        case .deletion: "-" + line.content
        case .context: " " + line.content
        case .metadata: line.content
        }
    }

    private static func range(of numbers: [Int]) -> ClosedRange<Int>? {
        guard let lower = numbers.min(), let upper = numbers.max() else {
            return nil
        }
        return lower...upper
    }

    private static func format(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound)-\(range.upperBound)"
    }

    /// 代码里自带 ``` 时用更长的围栏，避免提前结束代码块。
    private static func fence(for code: String) -> String {
        var longest = 0
        var current = 0
        for character in code {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

/// 双栏一行可能同时有删除和新增；按 unified diff 的顺序排：连续变更块里先删除后新增，
/// 上下文行和不相邻的行把块断开。上下文行在两栏是同一行，只保留一次。
func unifiedDiffSelectionOrder(_ rows: [(row: Int, old: GitDiffLine?, new: GitDiffLine?)]) -> [GitDiffLine] {
    var ordered: [GitDiffLine] = []
    var deletions: [GitDiffLine] = []
    var additions: [GitDiffLine] = []
    var previousRow: Int?
    func flush() {
        ordered += deletions
        ordered += additions
        deletions = []
        additions = []
    }
    for entry in rows.sorted(by: { $0.row < $1.row }) {
        if let previousRow, entry.row != previousRow + 1 {
            flush()
        }
        previousRow = entry.row
        let lines = [entry.old, entry.new].compactMap { $0 }
        let distinct = lines.count == 2 && lines[0].id == lines[1].id ? [lines[0]] : lines
        for line in distinct {
            switch line.kind {
            case .deletion:
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .context, .metadata:
                flush()
                ordered.append(line)
            }
        }
    }
    flush()
    return ordered
}

/// 把上下文交给 agent 会话的方式。
enum AgentContextDelivery: Equatable {
    /// 会话输入框里已经填好。
    case prefilled
    /// 宿主不支持带文字打开已有会话，已复制到剪贴板。
    case copiedToPasteboard
    case failed(String)
}

/// Codex 的线程链接支持 `prompt` 参数，打开后填进输入框、不自动发送；Claude Desktop 打开
/// 已有会话的链接不接收上下文文字，先复制到剪贴板，再由控制器通过辅助功能填写。
struct AgentSessionContextHandoff: Equatable {
    /// 链接太长时宿主和系统都可能截断，超过这个字符数改走剪贴板。
    static let maximumPrefillLength = 32_000
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    let url: URL
    let copiesContextToPasteboard: Bool

    init(provider: AgentProvider, sessionURL: URL, context: String) {
        guard provider == .codex,
              context.count <= Self.maximumPrefillLength,
              var components = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false),
              // 网页端按 URLSearchParams 解析，`+` 会被当成空格，所以只保留非保留字符。
              let encoded = context.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
            url = sessionURL
            copiesContextToPasteboard = true
            return
        }
        let existing = components.percentEncodedQuery.map { $0.isEmpty ? "" : $0 + "&" } ?? ""
        components.percentEncodedQuery = existing + "prompt=" + encoded
        guard let prefilledURL = components.url else {
            url = sessionURL
            copiesContextToPasteboard = true
            return
        }
        url = prefilledURL
        copiesContextToPasteboard = false
    }
}
