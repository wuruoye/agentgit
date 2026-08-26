import Foundation

public struct GitDiffLinePair: Hashable, Sendable {
    public let old: GitDiffLine?
    public let new: GitDiffLine?

    public init(old: GitDiffLine?, new: GitDiffLine?) {
        self.old = old
        self.new = new
    }
}

/// 把 unified diff 的删除/新增 run 对齐成双栏行；context 在两栏各显示一次。
public enum SideBySideDiffBuilder {
    public static func pairs(_ lines: [GitDiffLine]) -> [GitDiffLinePair] {
        var result: [GitDiffLinePair] = []
        var index = 0

        while index < lines.count {
            switch lines[index].kind {
            case .deletion:
                let deletionStart = index
                while index < lines.count, lines[index].kind == .deletion {
                    index += 1
                }
                let additionStart = index
                while index < lines.count, lines[index].kind == .addition {
                    index += 1
                }
                let deletionCount = additionStart - deletionStart
                let additionCount = index - additionStart
                for offset in 0..<max(deletionCount, additionCount) {
                    result.append(
                        GitDiffLinePair(
                            old: offset < deletionCount ? lines[deletionStart + offset] : nil,
                            new: offset < additionCount ? lines[additionStart + offset] : nil
                        )
                    )
                }

            case .addition:
                result.append(GitDiffLinePair(old: nil, new: lines[index]))
                index += 1

            case .context, .metadata:
                result.append(GitDiffLinePair(old: lines[index], new: lines[index]))
                index += 1
            }
        }

        return result
    }
}
