import Foundation

public enum GitSyntaxLanguage: Hashable, Sendable {
    case plain
    case swift
    case cLike
    case python
    case shell
    case json
    case yaml
    case markdown
    case sql

    public init(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "swift": self = .swift
        case "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm",
             "java", "kt", "kts", "js", "jsx", "ts", "tsx", "dart", "rs", "go":
            self = .cLike
        case "py", "pyi": self = .python
        case "sh", "bash", "zsh", "fish": self = .shell
        case "json", "json5": self = .json
        case "yaml", "yml", "toml": self = .yaml
        case "md", "markdown": self = .markdown
        case "sql": self = .sql
        default:
            switch name {
            case "dockerfile", "makefile": self = .shell
            default: self = .plain
            }
        }
    }
}

public enum GitSyntaxTokenKind: Hashable, Sendable {
    case keyword
    case string
    case number
    case comment
    case heading
}

public struct GitSyntaxSpan: Hashable, Sendable {
    public let location: Int
    public let length: Int
    public let kind: GitSyntaxTokenKind

    public init(location: Int, length: Int, kind: GitSyntaxTokenKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

/// Diff 行的轻量词法高亮。只返回 UTF-16 区间，颜色由 AppKit 层决定。
public enum DiffSyntaxHighlighter {
    public static func spans(
        in content: String,
        language: GitSyntaxLanguage
    ) -> [GitSyntaxSpan] {
        guard language != .plain, !content.isEmpty else {
            return []
        }

        let text = content as NSString
        if language == .markdown, let heading = markdownHeading(in: text) {
            return [heading]
        }

        var spans: [GitSyntaxSpan] = []
        var index = 0
        while index < text.length {
            if startsBlockComment(text, at: index, language: language) {
                let end = blockCommentEnd(text, from: index + 2)
                spans.append(
                    GitSyntaxSpan(location: index, length: end - index, kind: .comment)
                )
                index = end
                continue
            }

            if startsLineComment(text, at: index, language: language) {
                spans.append(
                    GitSyntaxSpan(
                        location: index,
                        length: text.length - index,
                        kind: .comment
                    )
                )
                break
            }

            let unit = text.character(at: index)
            if isQuote(unit, language: language) {
                let end = stringEnd(text, from: index, quote: unit)
                spans.append(
                    GitSyntaxSpan(location: index, length: end - index, kind: .string)
                )
                index = end
                continue
            }

            if isASCIIDigit(unit) {
                let end = numberEnd(text, from: index)
                spans.append(
                    GitSyntaxSpan(location: index, length: end - index, kind: .number)
                )
                index = end
                continue
            }

            if isIdentifierStart(unit) {
                let end = identifierEnd(text, from: index)
                let word = text.substring(with: NSRange(location: index, length: end - index))
                if keywords(for: language).contains(word) {
                    spans.append(
                        GitSyntaxSpan(location: index, length: end - index, kind: .keyword)
                    )
                }
                index = end
                continue
            }

            index += 1
        }
        return spans
    }

    private static func markdownHeading(in text: NSString) -> GitSyntaxSpan? {
        var index = 0
        while index < text.length, text.character(at: index) == 0x20 {
            index += 1
        }
        let markerStart = index
        while index < text.length, text.character(at: index) == 0x23, index - markerStart < 6 {
            index += 1
        }
        guard index > markerStart,
              index < text.length,
              text.character(at: index) == 0x20 else {
            return nil
        }
        return GitSyntaxSpan(location: markerStart, length: text.length - markerStart, kind: .heading)
    }

    private static func startsLineComment(
        _ text: NSString,
        at index: Int,
        language: GitSyntaxLanguage
    ) -> Bool {
        switch language {
        case .swift, .cLike, .json:
            matches(text, at: index, token: "//")
        case .python, .shell, .yaml:
            text.character(at: index) == 0x23
        case .sql:
            matches(text, at: index, token: "--")
        case .markdown, .plain:
            false
        }
    }

    private static func startsBlockComment(
        _ text: NSString,
        at index: Int,
        language: GitSyntaxLanguage
    ) -> Bool {
        switch language {
        case .swift, .cLike, .json:
            matches(text, at: index, token: "/*")
        case .plain, .python, .shell, .yaml, .markdown, .sql:
            false
        }
    }

    private static func blockCommentEnd(_ text: NSString, from start: Int) -> Int {
        var index = start
        while index + 1 < text.length {
            if matches(text, at: index, token: "*/") {
                return index + 2
            }
            index += 1
        }
        return text.length
    }

    private static func isQuote(_ unit: unichar, language: GitSyntaxLanguage) -> Bool {
        if language == .markdown {
            return unit == 0x60
        }
        return unit == 0x22 || unit == 0x27 || (language == .cLike && unit == 0x60)
    }

    private static func stringEnd(_ text: NSString, from start: Int, quote: unichar) -> Int {
        let isTriple = start + 2 < text.length
            && text.character(at: start + 1) == quote
            && text.character(at: start + 2) == quote
        var index = start + (isTriple ? 3 : 1)
        var escaped = false
        while index < text.length {
            let unit = text.character(at: index)
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if unit == 0x5C {
                escaped = true
                index += 1
                continue
            }
            if isTriple,
               index + 2 < text.length,
               text.character(at: index + 1) == quote,
               text.character(at: index + 2) == quote {
                return index + 3
            }
            if !isTriple, unit == quote {
                return index + 1
            }
            index += 1
        }
        return text.length
    }

    private static func numberEnd(_ text: NSString, from start: Int) -> Int {
        var index = start + 1
        while index < text.length {
            let unit = text.character(at: index)
            guard isASCIIDigit(unit)
                    || isASCIIHexLetter(unit)
                    || unit == 0x2E
                    || unit == 0x5F else {
                break
            }
            index += 1
        }
        return index
    }

    private static func identifierEnd(_ text: NSString, from start: Int) -> Int {
        var index = start + 1
        while index < text.length, isIdentifierPart(text.character(at: index)) {
            index += 1
        }
        return index
    }

    private static func isIdentifierStart(_ unit: unichar) -> Bool {
        isASCIILetter(unit) || unit == 0x5F
    }

    private static func isIdentifierPart(_ unit: unichar) -> Bool {
        isIdentifierStart(unit) || isASCIIDigit(unit)
    }

    private static func isASCIILetter(_ unit: unichar) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isASCIIDigit(_ unit: unichar) -> Bool {
        (0x30...0x39).contains(unit)
    }

    private static func isASCIIHexLetter(_ unit: unichar) -> Bool {
        (0x41...0x46).contains(unit)
            || (0x61...0x66).contains(unit)
            || unit == 0x78
            || unit == 0x58
    }

    private static func matches(_ text: NSString, at index: Int, token: String) -> Bool {
        let tokenLength = (token as NSString).length
        guard index + tokenLength <= text.length else {
            return false
        }
        return text.substring(with: NSRange(location: index, length: tokenLength)) == token
    }

    private static func keywords(for language: GitSyntaxLanguage) -> Set<String> {
        switch language {
        case .swift: swiftKeywords
        case .cLike: cLikeKeywords
        case .python: pythonKeywords
        case .shell: shellKeywords
        case .json, .yaml: dataKeywords
        case .sql: sqlKeywords
        case .plain, .markdown: []
        }
    }

    private static let swiftKeywords: Set<String> = [
        "actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
        "class", "continue", "default", "defer", "deinit", "do", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard",
        "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let",
        "nonisolated", "nil", "open", "operator", "private", "protocol", "public",
        "repeat", "rethrows", "return", "self", "some", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"
    ]

    private static let cLikeKeywords: Set<String> = [
        "abstract", "as", "async", "await", "bool", "break", "case", "catch", "char",
        "class", "const", "continue", "default", "defer", "do", "double", "else", "enum",
        "export", "extends", "false", "final", "float", "for", "fun", "function", "if",
        "implements", "import", "in", "instanceof", "int", "interface", "let", "long",
        "match", "namespace", "new", "nil", "null", "override", "package", "private",
        "protected", "public", "return", "short", "static", "string", "struct", "super",
        "switch", "this", "throw", "true", "try", "type", "typeof", "union", "unsigned",
        "using", "var", "virtual", "void", "while", "yield"
    ]

    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
        "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
        "True", "try", "while", "with", "yield"
    ]

    private static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in",
        "select", "then", "time", "until", "while"
    ]

    private static let dataKeywords: Set<String> = [
        "false", "null", "true", "False", "None", "True", "no", "off", "on", "yes"
    ]

    private static let sqlKeywords: Set<String> = [
        "ADD", "ALTER", "AND", "AS", "ASC", "BEGIN", "BY", "CASE", "CREATE", "DELETE",
        "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FALSE", "FROM", "FULL",
        "GROUP", "HAVING", "IN", "INNER", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIKE",
        "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER", "RIGHT", "SELECT", "SET",
        "TABLE", "THEN", "TRUE", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE", "WITH"
    ]
}
