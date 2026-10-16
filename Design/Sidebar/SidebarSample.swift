import AppKit
import SwiftUI

/// 截图坐标除以 2 得到样板坐标；导出时以 2× 还原，不受应用字号设置影响。
enum SidebarSampleSpec {
    static let size = CGSize(width: 455, height: 982)
    static let scale: CGFloat = 2
    static let bodySize: CGFloat = 16
    static let titleSize: CGFloat = 15.7
    static let detailSize: CGFloat = 14.5
    static let rowHeight: CGFloat = 60
    static let selectedRowHeight: CGFloat = 57.5
    static let textInset: CGFloat = 22
    static let rowInset: CGFloat = 9.5
    static let rowTrailingInset: CGFloat = 12.5

    static let background = color(0xFAF9F7)
    static let primary = color(0x41403D)
    static let secondary = color(0x76746E)
    static let selectedText = color(0x0B0B0B)
    static let selection = color(0xEDEBE7)
    static let hover = color(0xF1F0EC)
    static let search = color(0xFDFDFB)
    static let border = color(0xDFDFDD)
    static let iconFill = color(0xE5E4DD)

    static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255, opacity: 1)
    }
}

struct SampleTypography {
    let face: String

    func font(_ size: CGFloat) -> Font {
        guard let font = NSFont(name: "AnthropicSansVariable-Text\(face)", size: size) else {
            fatalError("Anthropic Sans \(face) is unavailable")
        }
        return Font(font)
    }
}

enum SampleContent {
    case calibration, agentgit
}

struct SidebarSample: View {
    let content: SampleContent
    let typography: SampleTypography

    private var isCalibration: Bool { content == .calibration }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
                .padding(.top, 21)
                .padding(.leading, 12)
                .padding(.trailing, 15)
            navigation
                .padding(.top, 9)
            VStack(alignment: .leading, spacing: 0) {
                if isCalibration {
                    groupTitle("Pinned")
                    calibrationPinnedRow
                        .padding(.top, 2)
                    groupTitle("Today", hasAction: true)
                        .padding(.top, 13.5)
                } else {
                    groupTitle("agentgit")
                    SidebarSampleRow(title: "main", detail: "Claude Desktop 风格 UI 重构",
                                     selected: false, hovered: false, isPinned: true, typography: typography)
                        .padding(.top, 2)
                }
                sampleRow(
                    isCalibration ? "分享组织：vibe 工具与 AI 助理" : "codex/sidebar-layout",
                    detail: isCalibration ? "agents" : "侧栏样板与视觉对照",
                    selected: true
                )
                .padding(.top, 3)
                groupTitle(isCalibration ? "Yesterday" : "wechat-lfs")
                    .padding(.top, 16)
                sampleRow(isCalibration ? "Agent 上下文压缩方案" : "dev/trunk/urgen-finalizer_release",
                          detail: isCalibration ? "mini-harness" : "继续处理 Android Test 包 WCR 检查与 1K 放量")
                sampleRow(isCalibration ? "Agent权限管理研究" : "dev/trunk/urgen-finalizer",
                          detail: isCalibration ? "mini-harness" : "未知 pb 字段异常")
                sampleRow(isCalibration ? "代码审查和提交" : "dev/trunk/thread-helper-self-reap",
                          detail: isCalibration ? "agents" : "threadHelper 依赖分析")
                sampleRow(isCalibration ? "ThreadHelper 自线程析构修复：Android 安装运行验证" : "dev/test/sigmaqzhang_urgen_finalizer",
                          detail: isCalibration ? "wl" : "未知 pb 字段异常：落地 finalizer 生成器修复")
                if !isCalibration { moreWorktrees }
                groupTitle(isCalibration ? "Oct 13" : "case-driven")
                    .padding(.top, 14.5)
                sampleRow(isCalibration ? "IAM AffExpt Android/iOS integration" : "codex/deploy-failure-notifications",
                          detail: isCalibration ? "wl" : "排查 slot 发布失败并添加通知")
                sampleRow(isCalibration ? "子任务并行调整确认" : "codex/session-detail-ui-plan",
                          detail: isCalibration ? "agents" : "会话详情与窄栏布局")
            }
            .padding(.top, 25.5)
            Spacer(minLength: 0)
        }
        .frame(width: SidebarSampleSpec.size.width, height: SidebarSampleSpec.size.height, alignment: .topLeading)
        .background(SidebarSampleSpec.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(SidebarSampleSpec.border.opacity(0.7)).frame(width: 0.5)
        }
        .environment(\.colorScheme, .light)
    }

    private var search: some View {
        HStack(spacing: 10) {
            SampleIcon(kind: .search).frame(width: 16, height: 16)
            Text("Search").font(typography.font(16))
            Spacer(minLength: 0)
        }
        .foregroundStyle(SidebarSampleSpec.secondary)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(SidebarSampleSpec.search, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(SidebarSampleSpec.border, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.065), radius: 1.5, y: 1)
    }

    private var navigation: some View {
        VStack(spacing: 0) {
            navigationRow("New", icon: .plus, new: true)
            navigationRow("Projects", icon: .projects, badge: isCalibration ? "Beta" : nil)
            navigationRow(isCalibration ? "Artifacts" : "Worktrees", icon: .artifacts)
            navigationRow("Customize", icon: .briefcase)
            navigationRow("More", icon: .more)
        }
    }

    private func navigationRow(_ title: String, icon: SampleIcon.Kind, new: Bool = false, badge: String? = nil) -> some View {
        HStack(spacing: 9) {
            SampleIcon(kind: icon)
                .frame(width: 16, height: 16)
                .frame(width: 21, height: 21)
                .background {
                    if new { Circle().fill(SidebarSampleSpec.iconFill).frame(width: 22, height: 22) }
                }
            Text(title).font(typography.font(SidebarSampleSpec.bodySize))
            if let badge {
                Text(badge).font(typography.font(13))
                    .padding(.horizontal, 5).frame(height: 19)
                    .background(SidebarSampleSpec.selection, in: RoundedRectangle(cornerRadius: 5))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(SidebarSampleSpec.primary)
        .padding(.leading, 20.5)
        .padding(.trailing, 16)
        .frame(height: 32)
    }

    private func groupTitle(_ title: String, hasAction: Bool = false) -> some View {
        HStack {
            Text(title).font(typography.font(SidebarSampleSpec.detailSize))
            Spacer()
            if hasAction { SampleIcon(kind: .plus).frame(width: 14, height: 14) }
        }
        .foregroundStyle(SidebarSampleSpec.secondary)
        .padding(.horizontal, SidebarSampleSpec.textInset)
        .frame(height: 28)
    }

    private var calibrationPinnedRow: some View {
        HStack(spacing: 9) {
            SampleIcon(kind: .code).frame(width: 19, height: 19)
            Text("Harness agent 学习方案")
                .font(typography.font(SidebarSampleSpec.titleSize))
                .lineLimit(1)
            Spacer(minLength: 0)
            Circle().fill(SidebarSampleSpec.color(0xFFAE05)).frame(width: 7, height: 7)
        }
        .foregroundStyle(SidebarSampleSpec.primary)
        .padding(.leading, SidebarSampleSpec.textInset)
        .padding(.trailing, 25)
        .frame(height: 32)
    }

    private var moreWorktrees: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down").font(.system(size: 9))
            Text("Show 4 More Worktrees").font(typography.font(SidebarSampleSpec.detailSize))
            Spacer(minLength: 0)
        }
        .foregroundStyle(SidebarSampleSpec.secondary)
        .padding(.horizontal, SidebarSampleSpec.textInset)
        .frame(height: 28)
    }

    private func sampleRow(_ title: String, detail: String, selected: Bool = false) -> some View {
        SidebarSampleRow(title: title, detail: detail, selected: selected, hovered: false, typography: typography)
    }
}

struct SidebarSampleRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let hovered: Bool
    var isPinned = false
    let typography: SampleTypography

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(typography.font(SidebarSampleSpec.titleSize))
                    .foregroundStyle(selected ? SidebarSampleSpec.selectedText : SidebarSampleSpec.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(SidebarSampleSpec.secondary)
                }
            }
            .frame(height: 23, alignment: .leading)
            Text(detail)
                .font(typography.font(SidebarSampleSpec.detailSize))
                    .foregroundStyle(SidebarSampleSpec.secondary)
                    .frame(height: 21, alignment: .leading)
                    .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SidebarSampleSpec.textInset - SidebarSampleSpec.rowInset)
        .padding(.top, selected ? 3.5 : 5.5)
        .frame(height: selected ? SidebarSampleSpec.selectedRowHeight : SidebarSampleSpec.rowHeight, alignment: .top)
        .background(selected ? SidebarSampleSpec.selection : hovered ? SidebarSampleSpec.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .padding(.leading, SidebarSampleSpec.rowInset)
        .padding(.trailing, SidebarSampleSpec.rowTrailingInset)
    }
}

/// 用一致的线宽绘制样板图标，避免 SF Symbols 的字形宽度改变文字起点。
struct SampleIcon: View {
    enum Kind { case search, plus, projects, artifacts, briefcase, more, code }
    let kind: Kind

    var body: some View {
        GeometryReader { geometry in
            let sx = geometry.size.width / 24
            let sy = geometry.size.height / 24
            Path { path in
                switch kind {
                case .search:
                    path.addEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
                    path.move(to: CGPoint(x: 16, y: 16)); path.addLine(to: CGPoint(x: 23, y: 23))
                case .plus:
                    path.move(to: CGPoint(x: 5, y: 12)); path.addLine(to: CGPoint(x: 19, y: 12))
                    path.move(to: CGPoint(x: 12, y: 5)); path.addLine(to: CGPoint(x: 12, y: 19))
                case .projects:
                    path.move(to: CGPoint(x: 6, y: 3)); path.addLine(to: CGPoint(x: 18, y: 3))
                    path.move(to: CGPoint(x: 3, y: 8)); path.addLine(to: CGPoint(x: 21, y: 8))
                    path.addLine(to: CGPoint(x: 19, y: 21)); path.addLine(to: CGPoint(x: 5, y: 21)); path.closeSubpath()
                case .artifacts:
                    path.addRoundedRect(in: CGRect(x: 13, y: 10, width: 8, height: 10), cornerSize: CGSize(width: 1, height: 1))
                    path.addEllipse(in: CGRect(x: 2, y: 14, width: 7, height: 7))
                    path.move(to: CGPoint(x: 5, y: 14)); path.addLine(to: CGPoint(x: 5, y: 6))
                    path.addCurve(to: CGPoint(x: 13, y: 3), control1: CGPoint(x: 5, y: 1), control2: CGPoint(x: 11, y: 1))
                    path.addLine(to: CGPoint(x: 18, y: 6)); path.addLine(to: CGPoint(x: 7, y: 15))
                case .briefcase:
                    path.addRoundedRect(in: CGRect(x: 2, y: 7, width: 20, height: 15), cornerSize: CGSize(width: 2, height: 2))
                    path.addRoundedRect(in: CGRect(x: 7, y: 3, width: 10, height: 5), cornerSize: CGSize(width: 2, height: 2))
                    path.move(to: CGPoint(x: 2, y: 12)); path.addLine(to: CGPoint(x: 22, y: 12))
                case .more:
                    for x: CGFloat in [4, 12, 20] { path.addEllipse(in: CGRect(x: x - 0.8, y: 11.2, width: 1.6, height: 1.6)) }
                case .code:
                    path.move(to: CGPoint(x: 6, y: 7)); path.addLine(to: CGPoint(x: 1.5, y: 12)); path.addLine(to: CGPoint(x: 6, y: 17))
                    path.move(to: CGPoint(x: 18, y: 7)); path.addLine(to: CGPoint(x: 22.5, y: 12)); path.addLine(to: CGPoint(x: 18, y: 17))
                    path.move(to: CGPoint(x: 14, y: 4)); path.addLine(to: CGPoint(x: 10, y: 20))
                }
            }
            .applying(CGAffineTransform(scaleX: sx, y: sy))
            .stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        }
    }
}

@main
struct RenderSidebarSample {
    @MainActor
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = AgentGitTypography.interface()
        for face in ["Light"] {
            let typography = SampleTypography(face: face)
            for mode in [SampleContent.calibration, .agentgit] {
                let name = mode == .calibration ? "calibration" : "agentgit"
                let view = SidebarSample(content: mode, typography: typography)
                let renderer = ImageRenderer(content: view)
                renderer.scale = SidebarSampleSpec.scale
                guard let image = renderer.cgImage else { fatalError("Unable to render sidebar") }
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Unable to encode sidebar") }
                try png.write(to: destination.appendingPathComponent("\(name).png"))
            }
        }
        let states = VStack(alignment: .leading, spacing: 12) {
            ForEach(["普通", "悬停", "选中"], id: \.self) { state in
                Text(state).font(SampleTypography(face: "Light").font(14.5))
                    .foregroundStyle(SidebarSampleSpec.secondary).padding(.horizontal, 22)
                SidebarSampleRow(title: "codex/sidebar-layout", detail: "侧栏样板与视觉对照",
                                 selected: state == "选中", hovered: state == "悬停", typography: SampleTypography(face: "Light"))
            }
        }
        .padding(.vertical, 22)
        .frame(width: SidebarSampleSpec.size.width)
        .background(SidebarSampleSpec.background)
        .environment(\.colorScheme, .light)
        let stateRenderer = ImageRenderer(content: states)
        stateRenderer.scale = SidebarSampleSpec.scale
        guard let stateImage = stateRenderer.cgImage,
              let statePNG = NSBitmapImageRep(cgImage: stateImage).representation(using: .png, properties: [:]) else {
            fatalError("Unable to render row states")
        }
        try statePNG.write(to: destination.appendingPathComponent("row-states.png"))
        print(destination.path)
    }
}
