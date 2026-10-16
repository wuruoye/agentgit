import AppKit
import SwiftUI

enum ReviewWorkspaceStyle {
    static let commitTitleSize: CGFloat = 14
    static let metadataSize: CGFloat = 11.5
    static let titleSize: CGFloat = 15.5
    static let fileTitleSize: CGFloat = 13.5
    static let commitRowHeight: CGFloat = 56
    static let toolbarHeight: CGFloat = 56
    static let fileHeaderHeight: CGFloat = 52
    static let hunkHeaderHeight: CGFloat = 24
    static let primary = SidebarStyle.primary
    static let secondary = SidebarStyle.secondary
    static let selection = SidebarStyle.selection
    static let hover = SidebarStyle.hover

    static func font(_ size: CGFloat) -> Font {
        .agentGitInterface(size: size, weight: .light)
    }

    static func nativeFont(_ size: CGFloat) -> NSFont {
        AgentGitTypography.interface(ofSize: size, weight: .light)
    }
}

enum WorkspaceMotion {
    static let hoverDuration: Double = 0.12
    static let pressDuration: Double = 0.08
    static let layoutDuration: Double = 0.20

    static func hover(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: hoverDuration)
    }

    static func layout(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: layoutDuration)
    }
}

enum ReviewControlMetrics {
    static let height: CGFloat = 28
    static let iconSize: CGFloat = 15
    static let horizontalPadding: CGFloat = 8
    static let iconTextSpacing: CGFloat = 6
    static let spacing: CGFloat = 6
    static let trailingInset: CGFloat = 12
    static let cornerRadius: CGFloat = 7
}

@MainActor
enum ReviewIcon: String, CaseIterable {
    case stage, unstage, review, reviewed, expand, collapse, discard, more
    case display, split, unified, focus, history, refresh, previous, next, close

    private static var cache: [ReviewIcon: NSImage] = [:]
    private static var actionImageCache: [ReviewIcon: NSImage] = [:]
    private static let resourceBundle: Bundle? = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.resourceURL
                .map { $0.appendingPathComponent("AgentGit_AgentGitApp.bundle") }
                .flatMap(Bundle.init(url:))
        }
        return Bundle.module
    }()

    var resourceURL: URL? {
        Self.resourceBundle?.url(forResource: rawValue, withExtension: "svg", subdirectory: "ReviewIcons")
    }

    var image: NSImage {
        if let cached = Self.cache[self] { return cached }
        let image = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            ?? resourceURL.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }

    var actionImage: NSImage {
        if let cached = Self.actionImageCache[self] { return cached }
        let image = self.image.copy() as! NSImage
        image.size = NSSize(width: ReviewControlMetrics.iconSize, height: ReviewControlMetrics.iconSize)
        Self.actionImageCache[self] = image
        return image
    }

    private var fallbackSymbol: String {
        switch self {
        case .stage: "arrow.down.to.line"
        case .unstage: "arrow.up.to.line"
        case .review: "square"
        case .reviewed: "checkmark.square.fill"
        case .expand: "arrow.up.and.down"
        case .collapse: "arrow.down.and.arrow.up"
        case .discard: "arrow.uturn.backward"
        case .more: "ellipsis"
        case .display: "slider.horizontal.3"
        case .split: "rectangle.split.2x1"
        case .unified: "rectangle"
        case .focus: "viewfinder"
        case .history: "clock.arrow.circlepath"
        case .refresh: "arrow.clockwise"
        case .previous: "chevron.up"
        case .next: "chevron.down"
        case .close: "xmark"
        }
    }
}

struct ReviewIconView: View {
    let icon: ReviewIcon
    var size: CGFloat = ReviewControlMetrics.iconSize

    var body: some View {
        Image(nsImage: icon.image)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 控件暂时不可见时保留原有布局，同时移除点击、键盘和无障碍入口。
    func workspaceControlSlot(isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .disabled(!isVisible)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

struct StableButtonTitle: View {
    let title: String
    let alternatives: [String]

    var body: some View {
        ZStack {
            ForEach(alternatives, id: \.self) { alternative in
                Text(alternative).hidden().accessibilityHidden(true)
            }
            Text(title)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

enum ReviewControlKind: Equatable { case normal, selected, primary, bordered, destructive }

struct InteractionBackground: View {
    let color: NSColor
    let isVisible: Bool
    var cornerRadius: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: color))
            .opacity(isVisible ? 1 : 0)
            .animation(WorkspaceMotion.hover(reduceMotion: reduceMotion), value: isVisible)
            .allowsHitTesting(false)
    }
}

struct WorkspaceActionLabelStyle: LabelStyle {
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: ReviewControlMetrics.iconTextSpacing) {
            configuration.icon
                .frame(width: ReviewControlMetrics.iconSize, height: ReviewControlMetrics.iconSize)
            if !iconOnly { configuration.title.fixedSize() }
        }
    }
}

private struct ReviewControlLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: ReviewControlMetrics.iconTextSpacing) {
            configuration.icon
                .frame(width: ReviewControlMetrics.iconSize, height: ReviewControlMetrics.iconSize)
            configuration.title
        }
    }
}

struct ReviewToolbarButtonStyle: ButtonStyle {
    var kind: ReviewControlKind = .normal
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        ReviewControlBody(configuration: configuration, kind: kind, iconOnly: iconOnly)
    }
}

private struct ReviewControlBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ReviewControlKind
    let iconOnly: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var fill: NSColor {
        if kind == .primary {
            return !isEnabled ? AgentGitPalette.activeControl
                : configuration.isPressed ? AgentGitPalette.primaryControlPressed
                : isHovered ? AgentGitPalette.primaryControlHover : AgentGitPalette.activeControl
        }
        if kind == .selected {
            return isEnabled && configuration.isPressed ? AgentGitPalette.controlPressed : AgentGitPalette.sidebarSelection
        }
        if kind == .destructive {
            return AgentGitPalette.reviewActionConfirmationBackground
        }
        return configuration.isPressed ? AgentGitPalette.controlPressed : AgentGitPalette.controlHover
    }

    private var showsBackground: Bool {
        kind == .primary || kind == .selected
            || (isEnabled && (isHovered || configuration.isPressed))
    }

    private var foreground: Color {
        if kind == .primary { return Color(nsColor: AgentGitPalette.primaryControlText) }
        if kind == .destructive && (isHovered || configuration.isPressed) { return Color(nsColor: AgentGitPalette.reviewActionConfirmationText) }
        return Color(nsColor: kind == .selected || isHovered ? AgentGitPalette.activeControl : AgentGitPalette.controlText)
    }

    var body: some View {
        configuration.label
            .labelStyle(ReviewControlLabelStyle())
            .font(.agentGitInterface(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, iconOnly ? 6 : ReviewControlMetrics.horizontalPadding)
            .frame(minWidth: ReviewControlMetrics.height, minHeight: ReviewControlMetrics.height)
            .background {
                InteractionBackground(color: fill, isVisible: showsBackground, cornerRadius: ReviewControlMetrics.cornerRadius)
            }
            .overlay {
                RoundedRectangle(cornerRadius: ReviewControlMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: AgentGitPalette.reviewControlBorder), lineWidth: 0.75)
                    .opacity(kind == .bordered ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: ReviewControlMetrics.cornerRadius))
            .onHover { isHovered = $0 }
            .animation(WorkspaceMotion.hover(reduceMotion: reduceMotion), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: WorkspaceMotion.pressDuration), value: configuration.isPressed)
            .animation(WorkspaceMotion.hover(reduceMotion: reduceMotion), value: kind)
    }
}

struct WorkspaceRowButtonStyle: ButtonStyle {
    var isSelected = false
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        WorkspaceRowButtonBody(configuration: configuration, isSelected: isSelected, cornerRadius: cornerRadius)
    }
}

private struct WorkspaceRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                InteractionBackground(
                    color: isSelected ? AgentGitPalette.sidebarSelection
                        : configuration.isPressed ? AgentGitPalette.controlPressed : AgentGitPalette.sidebarHover,
                    isVisible: isSelected || (isEnabled && (isHovered || configuration.isPressed)),
                    cornerRadius: cornerRadius
                )
                .animation(nil, value: isSelected)
                .animation(WorkspaceMotion.hover(reduceMotion: reduceMotion), value: configuration.isPressed)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovered = $0 }
    }
}
