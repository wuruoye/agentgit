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

enum ReviewSampleSpec {
    static let zoom: CGFloat = 1.1
    static let retina: CGFloat = 2
    static let physicalSize = CGSize(width: 2146, height: 1326)
    static let navigationWidth: CGFloat = 360
    static let dividerWidth: CGFloat = 1 / zoom
    static let primary = Color(nsColor: NSColor(srgbRed: 65 / 255, green: 64 / 255, blue: 61 / 255, alpha: 1))
    static let secondary = Color(nsColor: NSColor(srgbRed: 118 / 255, green: 116 / 255, blue: 110 / 255, alpha: 1))
    static let selection = Color(nsColor: NSColor(srgbRed: 237 / 255, green: 235 / 255, blue: 231 / 255, alpha: 1))
    static let hover = Color(nsColor: NSColor(srgbRed: 241 / 255, green: 240 / 255, blue: 236 / 255, alpha: 1))
    static let separator = Color(nsColor: NSColor(white: 0.91, alpha: 1))
    static let hunk = Color(nsColor: NSColor(white: 0.987, alpha: 1))

    static func font(_ size: CGFloat) -> Font {
        .agentGitInterface(size: size, weight: .light)
    }
}

enum SampleInteraction { case normal, hover, selected, disabled }

struct ReviewSampleButton: View {
    let symbol: String
    var title: String? = nil
    var state: SampleInteraction = .normal

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 15, height: 15)
            if let title { Text(title).font(ReviewSampleSpec.font(12)) }
        }
        .foregroundStyle(ReviewSampleSpec.primary)
        .padding(.horizontal, title == nil ? 7 : 8)
        .frame(minWidth: 28, minHeight: 28)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(state == .selected ? ReviewSampleSpec.selection : ReviewSampleSpec.hover)
                .opacity(state == .selected || state == .hover ? 1 : 0)
        }
        .opacity(state == .disabled ? 0.35 : 1)
    }
}

struct ReviewSampleCommitRow: View {
    let commit: ReviewFixture.Commit
    var state: SampleInteraction = .normal
    var showsReference = false

    private var referenceLabel: String? {
        guard showsReference, let reference = commit.references.first else { return nil }
        return reference.replacingOccurrences(of: "HEAD -> ", with: "")
            .replacingOccurrences(of: "tag: ", with: "")
    }

    private var referenceWidth: CGFloat {
        let font = AgentGitTypography.interface(ofSize: 10.5, weight: .light)
        return min(85, ceil(((referenceLabel ?? "") as NSString).size(withAttributes: [.font: font]).width))
    }

    var body: some View {
        HStack(spacing: 7) {
            Canvas { context, size in
                let x: CGFloat = 8
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.gray.opacity(0.43)), lineWidth: 1)
                context.fill(
                    Path(roundedRect: CGRect(x: x - 3, y: size.height / 2 - 3, width: 6, height: 6), cornerRadius: 1.5),
                    with: .color(state == .selected ? ReviewSampleSpec.primary.opacity(0.72) : .gray.opacity(0.65))
                )
            }
            .frame(width: 17, height: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(commit.subject)
                    .font(ReviewSampleSpec.font(14))
                    .foregroundStyle(ReviewSampleSpec.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    Text(commit.author).lineLimit(1)
                    if let referenceLabel {
                        Text(referenceLabel)
                            .font(ReviewSampleSpec.font(10.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: referenceWidth, alignment: .leading)
                            .padding(.horizontal, 5)
                            .frame(height: 17)
                            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
                        if commit.references.count > 1 {
                            Text("+\(commit.references.count - 1)").font(ReviewSampleSpec.font(10.5))
                        }
                    }
                    Spacer(minLength: 4)
                    Text(commit.date).fixedSize()
                }
                .font(ReviewSampleSpec.font(11.5))
                .foregroundStyle(ReviewSampleSpec.secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 56)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(state == .selected ? ReviewSampleSpec.selection : ReviewSampleSpec.hover)
                .opacity(state == .selected || state == .hover ? 1 : 0)
        }
        .opacity(state == .disabled ? 0.4 : 1)
    }
}

struct ReviewSampleNavigation: View {
    let fixture: ReviewFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 20) {
                Text("Commits")
                    .foregroundStyle(ReviewSampleSpec.primary)
                    .frame(height: 38)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1).fill(ReviewSampleSpec.primary).frame(height: 1.5)
                    }
                Text("Files").foregroundStyle(ReviewSampleSpec.secondary)
                Spacer(minLength: 0)
            }
            .font(ReviewSampleSpec.font(13.5))
            .padding(.horizontal, 18)
            .frame(height: 56)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                Text("Search commits").font(ReviewSampleSpec.font(12))
                Spacer()
            }
            .foregroundStyle(ReviewSampleSpec.secondary.opacity(0.8))
            .padding(.horizontal, 18)
            .frame(height: 32)
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .light))
                Text("Working tree clean").font(ReviewSampleSpec.font(12))
                Spacer()
            }
            .foregroundStyle(ReviewSampleSpec.secondary)
            .padding(.horizontal, 18)
            .frame(height: 44)
            Rectangle().fill(ReviewSampleSpec.separator.opacity(0.65)).frame(height: 0.5)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(fixture.commits.enumerated()), id: \.element.id) { index, commit in
                    ReviewSampleCommitRow(commit: commit, state: index == 0 ? .selected : .normal, showsReference: !commit.references.isEmpty)
                }
            }
            .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .frame(width: ReviewSampleSpec.navigationWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Color.white)
    }
}

struct ReviewSampleToolbar: View {
    let fixture: ReviewFixture
    var compact = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(fixture.commits[0].subject)
                    .font(ReviewSampleSpec.font(15.5))
                    .foregroundStyle(ReviewSampleSpec.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 9) {
                    Text("\(fixture.files.count) files")
                    diffCounts(added: fixture.added, deleted: fixture.deleted)
                    if !compact { Text("·"); Text("0/\(fixture.files.count) reviewed") }
                }
                .font(ReviewSampleSpec.font(12))
                .foregroundStyle(ReviewSampleSpec.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 1) {
                ReviewSampleButton(symbol: "rectangle", title: compact ? nil : "Unified", state: .selected)
                ReviewSampleButton(symbol: "rectangle.split.2x1", title: compact ? nil : "Split")
            }
            .padding(2)
            .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 2) {
                ReviewSampleButton(symbol: "slider.horizontal.3")
                ReviewSampleButton(symbol: "ellipsis")
            }
            Rectangle().fill(ReviewSampleSpec.separator).frame(width: 0.5, height: 16)
            HStack(spacing: 1) {
                ReviewSampleButton(symbol: "chevron.up", state: .disabled)
                Text("1 / \(fixture.files.reduce(0) { $0 + $1.hunks.count })")
                    .font(ReviewSampleSpec.font(11.5).monospacedDigit())
                    .foregroundStyle(ReviewSampleSpec.secondary)
                    .frame(minWidth: 34)
                ReviewSampleButton(symbol: "chevron.down")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(Color.white)
    }
}

func diffCounts(added: Int, deleted: Int) -> some View {
    HStack(spacing: 8) {
        Text("+\(added)").foregroundStyle(Color(nsColor: AgentGitPalette.additionText))
        Text("−\(deleted)").foregroundStyle(Color(nsColor: AgentGitPalette.deletionText))
    }
    .monospacedDigit()
    .fixedSize()
}

struct ReviewSampleFileHeader: View {
    let file: ReviewFixture.File
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(ReviewSampleSpec.secondary)
                .frame(width: 32)
            Text("M")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: AgentGitPalette.statusModified))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(ReviewSampleSpec.font(13.5)).foregroundStyle(ReviewSampleSpec.primary)
                Text(file.directory).font(ReviewSampleSpec.font(11.5)).foregroundStyle(ReviewSampleSpec.secondary)
            }
            .lineLimit(1)
            .frame(width: compact ? 180 : 280, alignment: .leading)
            diffCounts(added: file.added, deleted: file.deleted)
                .font(ReviewSampleSpec.font(11.5))
                .frame(width: 72, alignment: .trailing)
                .padding(.trailing, 18)
            ReviewSampleButton(symbol: "doc.text", title: compact ? nil : "Whole file")
            ReviewSampleButton(symbol: "square")
            ReviewSampleButton(symbol: "ellipsis")
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .frame(height: 52)
        .background(Color.white)
    }
}

func highlightedCode(_ source: String) -> Text {
    let pattern = #"(#[^\n]*|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:def|class|if|else|return|True|False|None|import|from|self|for|with|new|public|void)\b)"#
    let expression = try! NSRegularExpression(pattern: pattern)
    let sourceText = source as NSString
    let matches = expression.matches(in: source, range: NSRange(location: 0, length: sourceText.length))
    var cursor = 0
    var result = AttributedString()
    func append(_ text: String, color: NSColor) {
        var run = AttributedString(text)
        run.foregroundColor = Color(nsColor: color)
        result.append(run)
    }
    for match in matches {
        if match.range.location > cursor {
            append(sourceText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), color: AgentGitPalette.codeText)
        }
        let token = sourceText.substring(with: match.range)
        let color = token.hasPrefix("#") || token.hasPrefix("//") ? AgentGitPalette.syntaxComment
            : token.hasPrefix("\"") || token.hasPrefix("'") ? AgentGitPalette.syntaxString : AgentGitPalette.syntaxKeyword
        append(token, color: color)
        cursor = NSMaxRange(match.range)
    }
    if cursor < sourceText.length {
        append(sourceText.substring(from: cursor), color: AgentGitPalette.codeText)
    }
    return Text(result)
}

struct ReviewSampleCodeLine: View {
    let line: ReviewFixture.Line

    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                Text(line.old.map(String.init) ?? "")
                    .frame(width: 32, alignment: .trailing)
                Text(line.new.map(String.init) ?? "")
                    .frame(width: 32, alignment: .trailing)
                Text(line.kind == "addition" ? "+" : line.kind == "deletion" ? "−" : "")
                    .foregroundStyle(line.kind == "addition" ? Color(nsColor: AgentGitPalette.additionText) : Color(nsColor: AgentGitPalette.deletionText))
                    .frame(width: 16)
                highlightedCode(line.text)
                    .font(Font(AgentGitTypography.code))
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Color(nsColor: AgentGitPalette.codeLineNumber))
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .frame(height: 20)
        .background(line.kind == "addition" ? Color(nsColor: AgentGitPalette.additionBackground)
            : line.kind == "deletion" ? Color(nsColor: AgentGitPalette.deletionBackground) : Color.white)
        .clipped()
    }
}

struct ReviewSampleDiff: View {
    let fixture: ReviewFixture
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            ReviewSampleToolbar(fixture: fixture, compact: compact)
            Rectangle().fill(ReviewSampleSpec.separator).frame(height: 0.5)
            VStack(spacing: 8) {
                ForEach(fixture.files) { file in
                    VStack(spacing: 0) {
                        ReviewSampleFileHeader(file: file, compact: compact)
                        ForEach(file.hunks) { hunk in
                            HStack(spacing: 8) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 11, weight: .regular))
                                    .frame(width: 16)
                                Text(hunk.title.isEmpty ? hunk.header : hunk.title)
                                    .font(ReviewSampleSpec.font(11.5))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 10))
                                    .padding(.trailing, 16)
                            }
                            .foregroundStyle(ReviewSampleSpec.secondary.opacity(0.85))
                            .padding(.leading, 56)
                            .frame(height: 24)
                            .background(ReviewSampleSpec.hunk)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                ReviewSampleCodeLine(line: line)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .clipped()
    }
}

struct ReviewSampleWorkspace: View {
    let fixture: ReviewFixture
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ReviewSampleNavigation(fixture: fixture)
            Rectangle().fill(ReviewSampleSpec.separator).frame(width: ReviewSampleSpec.dividerWidth)
            ReviewSampleDiff(fixture: fixture, compact: compact)
        }
        .background(Color.white)
    }
}

@main
struct RenderReviewSample {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        _ = AgentGitTypography.interface()
        guard NSFont(name: "AnthropicSansVariable-TextLight", size: 14) != nil else {
            fatalError("Anthropic Sans Text Light is required for this comparison")
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fixture = try JSONDecoder().decode(ReviewFixture.self, from: Data(contentsOf: fixtureURL))

        func render<V: View>(_ view: V, size: CGSize, name: String) throws {
            let content = view
                .frame(width: size.width / ReviewSampleSpec.zoom, height: size.height / ReviewSampleSpec.zoom, alignment: .topLeading)
                .scaleEffect(ReviewSampleSpec.zoom, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white)
                .clipped()
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = ReviewSampleSpec.retina
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("Unable to render \(name)")
            }
            try png.write(to: destination.appendingPathComponent("\(name).png"))
        }
        try render(ReviewSampleWorkspace(fixture: fixture), size: ReviewSampleSpec.physicalSize, name: "proposal")
        try render(ReviewSampleWorkspace(fixture: fixture, compact: true), size: CGSize(width: 1160, height: 820), name: "proposal-narrow")
        let states = VStack(alignment: .leading, spacing: 18) {
            ForEach(["普通", "悬停", "选中", "禁用"], id: \.self) { title in
                let state: SampleInteraction = title == "普通" ? .normal : title == "悬停" ? .hover : title == "选中" ? .selected : .disabled
                HStack(spacing: 24) {
                    Text(title).font(ReviewSampleSpec.font(12)).frame(width: 40)
                    ReviewSampleCommitRow(commit: fixture.commits[0], state: state, showsReference: true)
                        .frame(width: 348)
                    ReviewSampleButton(symbol: "doc.text", title: "Whole file", state: state)
                    ReviewSampleButton(symbol: "square", state: state)
                }
            }
        }
        .padding(24)
        .foregroundStyle(ReviewSampleSpec.secondary)
        .background(Color.white)
        try render(states, size: CGSize(width: 740, height: 385), name: "states")
        let metadata: [String: Any] = [
            "zoom": ReviewSampleSpec.zoom, "retina": ReviewSampleSpec.retina,
            "workspace_pixels": [4292, 2652], "navigation_pixels": 792,
            "font": "AnthropicSansVariable-TextLight",
            "sizes_pt": ["commit_title": 14, "metadata": 11.5, "review_title": 15.5, "file_title": 13.5, "code": 13],
            "row_heights_pt": ["commit": 56, "toolbar": 56, "file": 52, "hunk": 24, "code": 20],
            "files": fixture.files.count, "hunks": fixture.files.reduce(0) { $0 + $1.hunks.count },
            "added": fixture.added, "deleted": fixture.deleted
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("render-metadata.json"))
        print(destination.path)
    }
}
