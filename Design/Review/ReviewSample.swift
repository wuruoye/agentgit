import AppKit
import SwiftUI

struct ReviewFixture: Decodable {
    struct Commit: Decodable, Identifiable {
        let id: String
        let subject: String
        let author: String
        let date: String
        let references: [String]
    }
    struct File: Decodable, Identifiable {
        let path: String
        let hunks: [Hunk]
        let added: Int
        let deleted: Int
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var directory: String { (path as NSString).deletingLastPathComponent }
    }
    struct Hunk: Decodable, Identifiable {
        let id: String
        let title: String
        let header: String
        let lines: [Line]

        /// `@@ -a,b +c,d @@` 里新文件一侧的起始行和行数。
        var newRange: (start: Int, count: Int) {
            let expression = try! NSRegularExpression(pattern: #"\+(\d+)(?:,(\d+))?"#)
            let text = header as NSString
            guard let match = expression.firstMatch(in: header, range: NSRange(location: 0, length: text.length)) else {
                return (1, 0)
            }
            let start = Int(text.substring(with: match.range(at: 1))) ?? 1
            let count = match.range(at: 2).location == NSNotFound ? 1 : Int(text.substring(with: match.range(at: 2))) ?? 0
            return (start, count)
        }
    }
    struct Line: Decodable {
        let kind: String
        let old: Int?
        let new: Int?
        let text: String
    }
    let commits: [Commit]
    let files: [File]
    let message: String
    let added: Int
    let deleted: Int
}

/// 样板直接取主应用的调色板、字号和语法高亮，只把布局用 SwiftUI 重画一遍。
enum ReviewSampleSpec {
    static let zoom: CGFloat = 1.1
    static let retina: CGFloat = 2
    static let physicalSize = CGSize(width: 2146, height: 1326)
    static let navigationWidth: CGFloat = 300
    static let toolbarHeight: CGFloat = 44
    static let fileHeaderHeight: CGFloat = 36
    static let gapHeight: CGFloat = 44
    static let hunkHeight: CGFloat = 24
    static let lineHeight: CGFloat = 20
    static let codeLeading: CGFloat = 64

    static func color(_ color: NSColor) -> Color { Color(nsColor: color) }
    static var primary: Color { color(AgentGitPalette.reviewPrimaryText) }
    static var secondary: Color { color(AgentGitPalette.reviewSecondaryText) }
    static var tertiary: Color { color(AgentGitPalette.reviewTertiaryText) }
    static var background: Color { color(AgentGitPalette.reviewBackground) }
    static var divider: Color { color(AgentGitPalette.reviewDivider) }

    static func font(_ size: CGFloat) -> Font {
        .agentGitInterface(size: size, weight: .light)
    }
}

enum SampleInteraction { case normal, hover, selected, toggledOn, disabled }

struct ReviewSampleIconButton: View {
    let symbol: String
    var title: String? = nil
    var state: SampleInteraction = .normal
    var rotation: Double = 0

    private var fill: NSColor? {
        switch state {
        case .hover: AgentGitPalette.controlHover
        case .selected: AgentGitPalette.reviewRowSelection
        case .toggledOn: AgentGitPalette.reviewToggleSelectedBackground
        case .normal, .disabled: nil
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .rotationEffect(.degrees(rotation))
                .frame(width: 15, height: 15)
            if let title { Text(title).font(ReviewSampleSpec.font(12)) }
        }
        .foregroundStyle(state == .toggledOn
            ? ReviewSampleSpec.color(AgentGitPalette.reviewToggleSelectedText)
            : ReviewSampleSpec.color(AgentGitPalette.controlText))
        .padding(.horizontal, title == nil ? 6 : 8)
        .frame(minWidth: 28, minHeight: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill.map(ReviewSampleSpec.color) ?? .clear)
        }
        .opacity(state == .disabled ? 0.45 : 1)
    }
}

struct ReviewSampleTopBar: View {
    let fixture: ReviewFixture

    var body: some View {
        HStack(spacing: 6) {
            ReviewSampleIconButton(symbol: "list.bullet", state: .toggledOn)
            HStack(spacing: 6) {
                Text("\(String(fixture.commits[0].id.prefix(13))) \(fixture.commits[0].subject)")
                    .font(ReviewSampleSpec.font(14.5))
                    .foregroundStyle(ReviewSampleSpec.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ReviewSampleSpec.secondary)
            }
            .padding(.leading, 4)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ReviewSampleIconButton(symbol: "magnifyingglass")
                ReviewSampleIconButton(symbol: "ellipsis", rotation: 90)
                ReviewSampleIconButton(symbol: "arrow.up.left.and.arrow.down.right")
                ReviewSampleIconButton(symbol: "xmark")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: ReviewSampleSpec.toolbarHeight)
        .background(ReviewSampleSpec.background)
    }
}

/// 左栏文件树：目录逐级缩进，文件行是 `</>` 图标、文件名和右侧的增删统计。
struct ReviewSampleFileTree: View {
    let files: [ReviewFixture.File]

    private enum Row: Identifiable {
        case folder(name: String, depth: Int)
        case file(ReviewFixture.File, depth: Int)
        var id: String {
            switch self {
            case let .folder(name, depth): "folder:\(depth):\(name)"
            case let .file(file, _): "file:\(file.path)"
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var openedPrefixes = Set<String>()
        for file in files.sorted(by: { $0.path < $1.path }) {
            let components = file.directory.split(separator: "/").map(String.init)
            for depth in components.indices {
                let prefix = components[...depth].joined(separator: "/")
                if openedPrefixes.insert(prefix).inserted {
                    rows.append(.folder(name: components[depth], depth: depth))
                }
            }
            rows.append(.file(file, depth: components.count))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case let .folder(name, depth):
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .rotationEffect(.degrees(90))
                            .foregroundStyle(ReviewSampleSpec.secondary)
                            .frame(width: 14)
                        Text(name).foregroundStyle(ReviewSampleSpec.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                    .frame(height: 26)
                case let .file(file, depth):
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(ReviewSampleSpec.tertiary)
                            .frame(width: 14)
                        Text(file.name).foregroundStyle(ReviewSampleSpec.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        sampleCounts(added: file.added, deleted: file.deleted, size: 12)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                    .frame(height: 26)
                }
            }
        }
        .font(ReviewSampleSpec.font(14))
        .lineLimit(1)
        .truncationMode(.middle)
    }
}

struct ReviewSampleCommitRow: View {
    let commit: ReviewFixture.Commit
    var state: SampleInteraction = .normal

    var body: some View {
        HStack(spacing: 7) {
            Canvas { context, size in
                let x = size.width / 2
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(ReviewSampleSpec.tertiary), lineWidth: 1)
                context.fill(
                    Path(roundedRect: CGRect(x: x - 3, y: size.height / 2 - 3, width: 6, height: 6), cornerRadius: 1.5),
                    with: .color(ReviewSampleSpec.secondary)
                )
            }
            .frame(width: 14, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.subject)
                    .font(ReviewSampleSpec.font(14))
                    .foregroundStyle(ReviewSampleSpec.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    Text(String(commit.id.prefix(13))).font(.system(size: 11.5, design: .monospaced))
                    Text(" · \(commit.author) · \(commit.date)")
                }
                .font(ReviewSampleSpec.font(12))
                .foregroundStyle(ReviewSampleSpec.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 54)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ReviewSampleSpec.color(state == .selected ? AgentGitPalette.reviewRowSelection : AgentGitPalette.reviewRowHover))
                .opacity(state == .selected || state == .hover ? 1 : 0)
        }
        .opacity(state == .disabled ? 0.45 : 1)
    }
}

struct ReviewSampleNavigation: View {
    let fixture: ReviewFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReviewSampleFileTree(files: fixture.files)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            Spacer(minLength: 0)
            Rectangle().fill(ReviewSampleSpec.divider).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ReviewSampleSpec.secondary)
                    .frame(width: 14)
                Text("Commits").foregroundStyle(ReviewSampleSpec.primary)
                Spacer()
                Text("\(fixture.commits.count)").foregroundStyle(ReviewSampleSpec.secondary)
            }
            .font(ReviewSampleSpec.font(14))
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: 38)
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(ReviewSampleSpec.secondary)
                        .frame(width: 14)
                    Text("Uncommitted changes").foregroundStyle(ReviewSampleSpec.primary)
                    Spacer()
                    Text("Clean").font(ReviewSampleSpec.font(12)).foregroundStyle(ReviewSampleSpec.secondary)
                }
                .font(ReviewSampleSpec.font(14))
                .padding(.horizontal, 8)
                .frame(height: 38)
                ForEach(Array(fixture.commits.prefix(7).enumerated()), id: \.element.id) { index, commit in
                    ReviewSampleCommitRow(commit: commit, state: index == 0 ? .selected : .normal)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 460, alignment: .top)
            .clipped()
        }
        .frame(width: ReviewSampleSpec.navigationWidth)
        .frame(maxHeight: .infinity)
        .background(ReviewSampleSpec.background)
    }
}

func sampleCounts(added: Int, deleted: Int, size: CGFloat) -> some View {
    HStack(spacing: 6) {
        Text("+\(added)").foregroundStyle(ReviewSampleSpec.color(AgentGitPalette.additionText))
        Text("-\(deleted)").foregroundStyle(ReviewSampleSpec.color(AgentGitPalette.deletionText))
    }
    .font(ReviewSampleSpec.font(size).monospacedDigit())
    .fixedSize()
}

struct ReviewSampleFileHeader: View {
    let file: ReviewFixture.File

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(ReviewSampleSpec.tertiary)
                .frame(width: 13)
                .padding(.leading, 14)
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ReviewSampleSpec.tertiary)
                .frame(width: 16)
                .padding(.leading, 6)
            Text(file.name)
                .font(ReviewSampleSpec.font(14))
                .foregroundStyle(ReviewSampleSpec.primary)
                .padding(.leading, 6)
            Text(file.directory)
                .font(ReviewSampleSpec.font(13))
                .foregroundStyle(ReviewSampleSpec.tertiary)
                .padding(.leading, 8)
            sampleCounts(added: file.added, deleted: file.deleted, size: 13)
                .padding(.leading, 10)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ReviewSampleIconButton(symbol: "doc.text", title: "Whole file")
                ReviewSampleIconButton(symbol: "square")
                ReviewSampleIconButton(symbol: "ellipsis")
            }
            .padding(.trailing, 12)
        }
        .lineLimit(1)
        .frame(height: ReviewSampleSpec.fileHeaderHeight)
        .background(ReviewSampleSpec.color(AgentGitPalette.reviewFileHeaderBackground))
        .overlay(alignment: .top) { Rectangle().fill(ReviewSampleSpec.divider).frame(height: 1) }
    }
}

/// 和主应用 `DiffSyntaxHighlighter` 同一套分词，颜色取调色板。
func highlightedCode(_ source: String, language: GitSyntaxLanguage) -> Text {
    let text = source as NSString
    var result = AttributedString()
    var cursor = 0
    func append(_ range: NSRange, _ color: NSColor) {
        guard range.length > 0 else { return }
        var run = AttributedString(text.substring(with: range))
        run.foregroundColor = ReviewSampleSpec.color(color)
        result.append(run)
    }
    for span in DiffSyntaxHighlighter.spans(in: source, language: language) where span.location >= cursor {
        let color: NSColor = switch span.kind {
        case .keyword: AgentGitPalette.syntaxKeyword
        case .type: AgentGitPalette.syntaxType
        case .string: AgentGitPalette.syntaxString
        case .number: AgentGitPalette.syntaxNumber
        case .comment: AgentGitPalette.syntaxComment
        case .heading: AgentGitPalette.syntaxHeading
        }
        append(NSRange(location: cursor, length: span.location - cursor), AgentGitPalette.codeText)
        append(NSRange(location: span.location, length: min(span.length, text.length - span.location)), color)
        cursor = span.location + span.length
    }
    append(NSRange(location: cursor, length: max(0, text.length - cursor)), AgentGitPalette.codeText)
    return Text(result.characters.isEmpty ? AttributedString(" ") : result)
}

struct ReviewSampleCodeLine: View {
    let line: ReviewFixture.Line
    let language: GitSyntaxLanguage

    private var accent: NSColor? {
        switch line.kind {
        case "addition": AgentGitPalette.additionText
        case "deletion": AgentGitPalette.deletionText
        default: nil
        }
    }

    var body: some View {
        // 代码按原宽度排开，GeometryReader 让超出部分只被裁掉，不撑宽整列。
        GeometryReader { _ in
            content
        }
        .frame(height: ReviewSampleSpec.lineHeight)
        .background(ReviewSampleSpec.color(
            line.kind == "addition" ? AgentGitPalette.additionBackground
                : line.kind == "deletion" ? AgentGitPalette.deletionBackground
                : AgentGitPalette.codeBackground
        ))
        .clipped()
    }

    private var content: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accent.map(ReviewSampleSpec.color) ?? .clear)
                .frame(width: AgentGitPalette.diffChangeBarWidth)
            Text((line.kind == "deletion" ? line.old : line.new ?? line.old).map(String.init) ?? "")
                .foregroundStyle(ReviewSampleSpec.color(accent ?? AgentGitPalette.codeLineNumber))
                .frame(width: 40, alignment: .trailing)
                .padding(.leading, 1)
            Text(line.kind == "addition" ? "+" : line.kind == "deletion" ? "-" : "")
                .foregroundStyle(ReviewSampleSpec.color(accent ?? AgentGitPalette.codeLineNumber))
                .frame(width: 12)
                .padding(.leading, 2)
            highlightedCode(line.text, language: language)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, ReviewSampleSpec.codeLeading - 58)
            Spacer(minLength: 0)
        }
        .font(Font(AgentGitTypography.code))
        .frame(height: ReviewSampleSpec.lineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// hunk 之间的分隔行：「N unmodified lines」加函数名，没有折叠行时只剩一条矮行。
struct ReviewSampleGapRow: View {
    let hiddenLineCount: Int
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            if hiddenLineCount > 0 {
                Text(hiddenLineCount == 1 ? "1 unmodified line" : "\(hiddenLineCount) unmodified lines")
                    .font(ReviewSampleSpec.font(13))
                    .foregroundStyle(ReviewSampleSpec.secondary)
            }
            if !title.isEmpty {
                Text(title)
                    .font(ReviewSampleSpec.font(12))
                    .foregroundStyle(ReviewSampleSpec.tertiary)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.leading, 14)
        .frame(height: hiddenLineCount > 0 ? ReviewSampleSpec.gapHeight : ReviewSampleSpec.hunkHeight)
        .background(ReviewSampleSpec.background)
    }
}

struct ReviewSampleDiff: View {
    let fixture: ReviewFixture

    var body: some View {
        VStack(spacing: 0) {
            ForEach(fixture.files) { file in
                let language = GitSyntaxLanguage(path: file.path)
                ReviewSampleFileHeader(file: file)
                ForEach(Array(file.hunks.enumerated()), id: \.element.id) { index, hunk in
                    let previousEnd = index == 0 ? 1 : file.hunks[index - 1].newRange.start + file.hunks[index - 1].newRange.count
                    ReviewSampleGapRow(hiddenLineCount: max(0, hunk.newRange.start - previousEnd), title: hunk.title)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        ReviewSampleCodeLine(line: line, language: language)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ReviewSampleSpec.background)
        .clipped()
    }
}

struct ReviewSampleWorkspace: View {
    let fixture: ReviewFixture
    var showsNavigation = true

    var body: some View {
        VStack(spacing: 0) {
            ReviewSampleTopBar(fixture: fixture)
            HStack(alignment: .top, spacing: 0) {
                if showsNavigation {
                    ReviewSampleNavigation(fixture: fixture)
                    Rectangle().fill(ReviewSampleSpec.divider).frame(width: 1)
                }
                ReviewSampleDiff(fixture: fixture)
            }
        }
        .background(ReviewSampleSpec.background)
    }
}

@main
struct RenderReviewSample {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        _ = AgentGitTypography.interface()
        guard NSFont(name: "AnthropicSansVariable-TextLight", size: 14) != nil else {
            fatalError("Anthropic Sans Text Light is required for this comparison")
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fixture = try JSONDecoder().decode(ReviewFixture.self, from: Data(contentsOf: fixtureURL))

        func render<V: View>(_ view: V, size: CGSize, name: String, dark: Bool = false) throws {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSApp.appearance = appearance
            let content = view
                .frame(width: size.width / ReviewSampleSpec.zoom, height: size.height / ReviewSampleSpec.zoom, alignment: .topLeading)
                .scaleEffect(ReviewSampleSpec.zoom, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(ReviewSampleSpec.background)
                .clipped()
                .environment(\.colorScheme, dark ? .dark : .light)
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: content)
                renderer.scale = ReviewSampleSpec.retina
                png = renderer.cgImage.flatMap {
                    NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
                }
            }
            guard let png else { fatalError("Unable to render \(name)") }
            try png.write(to: destination.appendingPathComponent("\(name).png"))
        }
        try render(ReviewSampleWorkspace(fixture: fixture), size: ReviewSampleSpec.physicalSize, name: "proposal")
        try render(ReviewSampleWorkspace(fixture: fixture), size: ReviewSampleSpec.physicalSize, name: "proposal-dark", dark: true)
        try render(ReviewSampleWorkspace(fixture: fixture, showsNavigation: false), size: CGSize(width: 1160, height: 820), name: "proposal-narrow")
        let states = VStack(alignment: .leading, spacing: 18) {
            ForEach(["普通", "悬停", "选中", "开关打开", "禁用"], id: \.self) { title in
                let state: SampleInteraction = switch title {
                case "悬停": .hover
                case "选中": .selected
                case "开关打开": .toggledOn
                case "禁用": .disabled
                default: .normal
                }
                HStack(spacing: 24) {
                    Text(title).font(ReviewSampleSpec.font(12)).frame(width: 56)
                    ReviewSampleCommitRow(commit: fixture.commits[0], state: state == .toggledOn ? .normal : state)
                        .frame(width: 300)
                    ReviewSampleIconButton(symbol: "doc.text", title: "Whole file", state: state)
                    ReviewSampleIconButton(symbol: "list.bullet", state: state)
                }
            }
        }
        .padding(24)
        .foregroundStyle(ReviewSampleSpec.secondary)
        .background(ReviewSampleSpec.background)
        try render(states, size: CGSize(width: 740, height: 440), name: "states")
        let metadata: [String: Any] = [
            "zoom": ReviewSampleSpec.zoom, "retina": ReviewSampleSpec.retina,
            "workspace_pixels": [Int(ReviewSampleSpec.physicalSize.width * ReviewSampleSpec.retina),
                                 Int(ReviewSampleSpec.physicalSize.height * ReviewSampleSpec.retina)],
            "navigation_pt": ReviewSampleSpec.navigationWidth,
            "font": "AnthropicSansVariable-TextLight",
            "sizes_pt": ["review_title": 14.5, "file_title": 14, "tree_row": 14, "commit_title": 14, "metadata": 12, "code": 13],
            "row_heights_pt": ["toolbar": ReviewSampleSpec.toolbarHeight, "file": ReviewSampleSpec.fileHeaderHeight,
                               "gap": ReviewSampleSpec.gapHeight, "hunk": ReviewSampleSpec.hunkHeight,
                               "code": ReviewSampleSpec.lineHeight, "commit": 54],
            "files": fixture.files.count, "hunks": fixture.files.reduce(0) { $0 + $1.hunks.count },
            "added": fixture.added, "deleted": fixture.deleted
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("render-metadata.json"))
        print(destination.path)
    }
}
