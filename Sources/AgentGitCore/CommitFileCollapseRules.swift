import Foundation

/// 每行一条通配规则；无斜杠时匹配任意目录下的文件名，否则匹配仓库相对路径。
public struct CommitFileCollapseRules: Sendable {
    private struct Rule: Sendable {
        let matchesFilename: Bool
        let expression: NSRegularExpression
    }

    private let rules: [Rule]

    public init(_ text: String) {
        rules = text.components(separatedBy: .newlines).compactMap { line in
            var pattern = line.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }

            let isRooted = pattern.hasPrefix("/") || pattern.hasPrefix("./")
            if pattern.hasPrefix("./") {
                pattern.removeFirst(2)
            } else if pattern.hasPrefix("/") {
                pattern.removeFirst()
            }
            guard !pattern.isEmpty else { return nil }
            if pattern.hasSuffix("/") {
                pattern += "**"
            }
            guard let expression = try? NSRegularExpression(
                pattern: Self.expression(for: pattern),
                options: .dotMatchesLineSeparators
            ) else { return nil }
            return Rule(
                matchesFilename: !isRooted && !pattern.contains("/"),
                expression: expression
            )
        }
    }

    public func matches(_ path: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let filename = path.split(separator: "/").last.map(String.init) ?? path
        return rules.contains { rule in
            let candidate = rule.matchesFilename ? filename : path
            return rule.expression.firstMatch(
                in: candidate,
                range: NSRange(candidate.startIndex..., in: candidate)
            ) != nil
        }
    }

    private static func expression(for pattern: String) -> String {
        let characters = Array(pattern)
        var expression = "\\A"
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 2
                    if index < characters.count, characters[index] == "/" {
                        expression += "(?:[^/]+/)*"
                        index += 1
                    } else {
                        expression += ".*"
                    }
                } else {
                    expression += "[^/]*"
                    index += 1
                }
            case "?":
                expression += "[^/]"
                index += 1
            default:
                expression += NSRegularExpression.escapedPattern(for: String(characters[index]))
                index += 1
            }
        }
        return expression + "\\z"
    }
}
