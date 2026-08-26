import Foundation

public enum GitPatchSelectionError: Error, Equatable, Sendable {
    case noChangedLines
    case nonTextualDiff
}

/// 从当前 diff 中抽出选中的 changed lines，生成 `git apply --unidiff-zero` 可消费的 patch。
public enum GitPatchSelectionBuilder {
    public static func patch(
        for diff: GitFileDiff,
        selectedLineIDs: Set<GitDiffLine.ID>,
        treatsUntrackedAsNewFile: Bool = true
    ) throws -> Data {
        guard diff.state == .textual else {
            throw GitPatchSelectionError.nonTextualDiff
        }

        var hunkBodies: [String] = []
        for hunk in diff.hunks {
            hunkBodies.append(contentsOf: selectedHunks(in: hunk, ids: selectedLineIDs))
        }
        guard !hunkBodies.isEmpty else {
            throw GitPatchSelectionError.noChangedLines
        }

        let isNewFile = diff.change.indexStatus == "A"
            || (diff.change.isUntracked && treatsUntrackedAsNewFile)
        let oldPath = isNewFile ? "/dev/null" : "a/\(diff.change.originalPath ?? diff.change.path)"
        let newPath = "b/\(diff.change.path)"
        let oldHeader = oldPath == "/dev/null" ? oldPath : quotePath(oldPath)
        var headers = [
            "diff --git \(quotePath(oldPath == "/dev/null" ? "a/\(diff.change.path)" : oldPath)) \(quotePath(newPath))"
        ]
        if isNewFile {
            headers.append("new file mode 100644")
        }
        headers.append("--- \(oldHeader)")
        headers.append("+++ \(quotePath(newPath))")
        let patch = headers + hunkBodies
        return Data((patch.joined(separator: "\n") + "\n").utf8)
    }

    private struct Segment {
        let oldStart: Int
        let newStart: Int
        var oldCount = 0
        var newCount = 0
        var body: [String] = []
    }

    private static func selectedHunks(
        in hunk: GitDiffHunk,
        ids: Set<GitDiffLine.ID>
    ) -> [String] {
        var oldLine = hunk.oldStart
        var newLine = hunk.newStart
        var segment: Segment?
        var result: [String] = []

        func finish(_ segment: inout Segment?) {
            guard let value = segment else {
                return
            }
            let oldStart = value.oldCount == 0 ? max(0, value.oldStart - 1) : value.oldStart
            let newStart = value.newCount == 0 ? max(0, value.newStart - 1) : value.newStart
            result.append(
                "@@ -\(oldStart),\(value.oldCount) +\(newStart),\(value.newCount) @@"
            )
            result.append(contentsOf: value.body)
            segment = nil
        }

        for line in hunk.lines {
            switch line.kind {
            case .context:
                finish(&segment)
                oldLine += 1
                newLine += 1

            case .deletion:
                if ids.contains(line.id) {
                    if segment == nil {
                        segment = Segment(oldStart: oldLine, newStart: newLine)
                    }
                    segment?.oldCount += 1
                    segment?.body.append("-\(line.content)")
                } else {
                    finish(&segment)
                }
                oldLine += 1

            case .addition:
                if ids.contains(line.id) {
                    if segment == nil {
                        segment = Segment(oldStart: oldLine, newStart: newLine)
                    }
                    segment?.newCount += 1
                    segment?.body.append("+\(line.content)")
                } else {
                    finish(&segment)
                }
                newLine += 1

            case .metadata:
                if segment != nil {
                    segment?.body.append(line.content)
                }
                finish(&segment)
            }
        }
        finish(&segment)
        return result
    }

    private static func quotePath(_ path: String) -> String {
        guard path.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) else {
            return path
        }
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
