import AppKit
import CoreText
import SwiftUI

enum AgentGitTypography {
    static let interfaceSize: CGFloat = 13
    static let codeSize: CGFloat = 13

    private static let hasClaudeInterfaceFont: Bool = {
        let regularName = "AnthropicSansVariable-TextRegular"
        if NSFont(name: regularName, size: interfaceSize) != nil { return true }
        guard let claudeURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ) else { return false }
        let directory = claudeURL.appendingPathComponent("Contents/Resources/fonts")
        let fontURLs = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in fontURLs where url.lastPathComponent.hasPrefix("AnthropicSans-")
            && ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: regularName, size: interfaceSize) != nil
    }()

    static func interface(
        ofSize size: CGFloat = interfaceSize,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        let interfaceWeight: NSFont.Weight
        switch weight {
        case .regular: interfaceWeight = .light
        case .medium: interfaceWeight = .regular
        case .semibold: interfaceWeight = .medium
        default: interfaceWeight = weight
        }
        guard hasClaudeInterfaceFont else {
            return .systemFont(ofSize: size, weight: interfaceWeight)
        }
        let style: String
        switch interfaceWeight {
        case .heavy...: style = "Extrabold"
        case .bold...: style = "Bold"
        case .semibold...: style = "Semibold"
        case .medium...: style = "Medium"
        case ..<NSFont.Weight.regular: style = "Light"
        default: style = "Regular"
        }
        return NSFont(name: "AnthropicSansVariable-Text\(style)", size: size)
            ?? .systemFont(ofSize: size, weight: interfaceWeight)
    }

    static var code: NSFont {
        NSFont(name: "Menlo", size: codeSize)
            ?? NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    }
    static var codeEmphasized: NSFont {
        NSFontManager.shared.convert(code, toHaveTrait: .boldFontMask)
    }
}

extension Font {
    static func agentGitInterface(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        guard design == .default else {
            return .system(size: size, weight: weight, design: design)
        }
        let nativeWeight: NSFont.Weight
        switch weight {
        case .black: nativeWeight = .black
        case .heavy: nativeWeight = .heavy
        case .bold: nativeWeight = .bold
        case .semibold: nativeWeight = .semibold
        case .medium: nativeWeight = .medium
        case .light: nativeWeight = .light
        case .thin: nativeWeight = .thin
        case .ultraLight: nativeWeight = .ultraLight
        default: nativeWeight = .regular
        }
        return Font(AgentGitTypography.interface(ofSize: size, weight: nativeWeight))
    }

    static func agentGitInterface(_ style: Font.TextStyle) -> Font {
        let nativeStyle: NSFont.TextStyle
        switch style {
        case .largeTitle: nativeStyle = .largeTitle
        case .title: nativeStyle = .title1
        case .title2: nativeStyle = .title2
        case .title3: nativeStyle = .title3
        case .headline: nativeStyle = .headline
        case .subheadline: nativeStyle = .subheadline
        case .callout: nativeStyle = .callout
        case .footnote: nativeStyle = .footnote
        case .caption: nativeStyle = .caption1
        case .caption2: nativeStyle = .caption2
        default: nativeStyle = .body
        }
        let size = NSFont.preferredFont(forTextStyle: nativeStyle).pointSize
        return agentGitInterface(size: size, weight: style == .headline ? .semibold : .regular)
    }
}

enum AgentGitPalette {
    static let cardCornerRadius: CGFloat = 12
    static let canvas = adaptive(light: .white, dark: srgb(35, 35, 35))
    static let card = adaptive(light: .white, dark: srgb(35, 35, 35))
    static let cardBorder = adaptive(
        light: srgb(226, 226, 226), dark: srgb(61, 61, 61),
        highContrastLight: srgb(136, 136, 136), highContrastDark: srgb(148, 148, 148)
    )
    static let sidebarBackground = adaptive(light: srgb(248, 248, 248), dark: srgb(28, 28, 28))
    static let inputBackground = adaptive(light: srgb(250, 250, 250), dark: srgb(42, 42, 42))
    static let sidebarHover = blended(foreground: .labelColor, background: sidebarBackground, fraction: 0.045)
    // Review 区按 Claude Desktop 的 diff 面板配色：整块白底，文件标题行浅灰，分隔只用一条细线。
    // 深色沿用同样的层次：底色和 card 一致，标题行略亮一级，增删底色压低饱和度。
    static let reviewBackground = card
    static let reviewPrimaryText = adaptive(
        light: srgb(41, 40, 37), dark: srgb(236, 234, 228),
        highContrastLight: srgb(10, 10, 10), highContrastDark: srgb(250, 250, 250)
    )
    static let reviewSecondaryText = adaptive(
        light: srgb(115, 114, 108), dark: srgb(163, 161, 153),
        highContrastLight: srgb(70, 70, 66), highContrastDark: srgb(205, 204, 198)
    )
    static let reviewTertiaryText = adaptive(
        light: srgb(160, 159, 153), dark: srgb(118, 117, 111),
        highContrastLight: srgb(100, 100, 96), highContrastDark: srgb(170, 169, 163)
    )
    static let reviewDivider = adaptive(
        light: srgb(232, 231, 228), dark: srgb(56, 56, 54),
        highContrastLight: srgb(150, 150, 146), highContrastDark: srgb(140, 140, 136)
    )
    static let reviewFileHeaderBackground = adaptive(
        light: srgb(245, 245, 244), dark: srgb(44, 44, 42),
        highContrastLight: srgb(232, 232, 230), highContrastDark: srgb(58, 58, 56)
    )
    static let reviewRowSelection = adaptive(
        light: srgb(240, 239, 236), dark: srgb(54, 54, 51),
        highContrastLight: srgb(210, 209, 205), highContrastDark: srgb(84, 84, 80)
    )
    static let reviewRowHover = adaptive(light: srgb(246, 246, 244), dark: srgb(45, 45, 43))
    /// 顶栏切换按钮的选中态：浅蓝圆角底配蓝色图标。
    static let reviewToggleSelectedBackground = adaptive(light: srgb(226, 236, 252), dark: srgb(36, 52, 80))
    static let reviewToggleSelectedText = adaptive(light: srgb(37, 99, 214), dark: srgb(128, 174, 250))
    static let codeBackground = reviewBackground
    static let reviewContextGap = reviewRowHover
    static let reviewContextGapText = reviewSecondaryText
    static let fileHeader = reviewFileHeaderBackground
    static let fileContext = reviewBackground
    static let hunkHeader = reviewBackground
    /// 增删行最左侧的实心竖条宽度。
    static let diffChangeBarWidth: CGFloat = 3
    static let reviewActionConfirmationBackground = adaptive(light: srgb(255, 234, 234), dark: srgb(76, 41, 40))
    static let reviewActionConfirmationText = adaptive(light: srgb(181, 46, 44), dark: srgb(255, 133, 130))
    static let commitPrimaryText = NSColor.labelColor
    static let commitSecondaryText = adaptive(
        light: srgb(107, 107, 107), dark: srgb(165, 165, 165),
        highContrastLight: srgb(77, 77, 77), highContrastDark: srgb(207, 207, 207)
    )
    static let chrome = card
    static let selectedChrome = canvas
    static let imagePanel = card
    static let imageChecker = inputBackground
    static let activeControl = adaptive(light: srgb(46, 46, 46), dark: srgb(228, 228, 228))
    static let primaryControlText = adaptive(light: .white, dark: srgb(28, 28, 28))
    static let primaryControlHover = blended(foreground: primaryControlText, background: activeControl, fraction: 0.10)
    static let primaryControlPressed = blended(foreground: primaryControlText, background: activeControl, fraction: 0.18)
    static let controlText = adaptive(light: srgb(73, 73, 73), dark: srgb(187, 187, 187))
    static let controlHover = blended(foreground: activeControl, background: card, fraction: 0.065)
    static let controlPressed = blended(foreground: activeControl, background: card, fraction: 0.12)
    static let controlDisabled = adaptive(light: srgb(151, 151, 151), dark: srgb(112, 112, 112))
    static let focusIndicator = adaptive(light: srgb(116, 116, 116), dark: srgb(180, 180, 180))
    static let sidebarCardBackground = sidebarBackground
    static let sidebarCardBorder = cardBorder
    static let sidebarChrome = sidebarBackground
    static let sidebarInputBackground = card
    static let sidebarGroupHeader = sidebarBackground
    static let sidebarSelectionBorder = activeControl
    static let sidebarMetadata = commitSecondaryText
    static let sidebarDivider = cardBorder
    static let reviewChrome = card
    static let reviewNavigationBackground = reviewBackground
    static let reviewTabBarBackground = reviewBackground
    static let reviewHeaderBorder = reviewDivider
    static let reviewControlBackground = card
    static let reviewControlBorder = cardBorder
    static let reviewHover = reviewRowHover
    static let reviewHunkText = commitPrimaryText
    static let reviewActionBackground = inputBackground
    static let commitCountBackground = inputBackground
    static let groupHeader = reviewBackground
    static let folderHeader = reviewBackground
    static let fileListRow = reviewFileHeaderBackground
    static let fileHeaderBoundary = reviewDivider
    static let sidebarSelection = adaptive(
        light: srgb(239, 239, 239), dark: srgb(55, 55, 55),
        highContrastLight: srgb(203, 203, 203), highContrastDark: srgb(86, 86, 86)
    )
    static let fileHeaderFocused = blended(foreground: activeControl, background: reviewFileHeaderBackground, fraction: 0.05)

    static let codeText = adaptive(
        light: srgb(41, 40, 37),
        dark: srgb(222, 220, 214)
    )
    static let codeLineNumber = adaptive(
        light: srgb(163, 162, 156),
        dark: srgb(112, 111, 106)
    )
    static let codeGutter = reviewBackground
    /// Split 视图里一侧没有对应行时的空白格。
    static let codeFiller = adaptive(
        light: srgb(250, 250, 249),
        dark: srgb(31, 31, 30)
    )
    /// 跨行选区底色。系统选中色直接铺满会盖掉增删色带，压一点透明度让行底色透出来。
    static let codeSelection = NSColor.selectedTextBackgroundColor
        .withAlphaComponent(0.7)
    static let separator = cardBorder

    // 增删行整行铺浅绿、浅红；行号、符号和左侧竖条用同色系的实色。深色下底色压暗、降饱和，
    // 只让竖条和行号保持可辨的亮度。
    static let additionBackground = adaptive(
        light: srgb(233, 245, 233),
        dark: srgb(34, 53, 38),
        highContrastLight: srgb(210, 236, 212),
        highContrastDark: srgb(30, 72, 40)
    )
    static let deletionBackground = adaptive(
        light: srgb(252, 235, 235),
        dark: srgb(64, 35, 35),
        highContrastLight: srgb(246, 212, 212),
        highContrastDark: srgb(92, 34, 34)
    )
    static let metadataBackground = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: reviewBackground,
        fraction: 0.24
    )
    static let additionInline = adaptive(
        light: srgb(196, 232, 199),
        dark: srgb(44, 88, 54),
        highContrastLight: srgb(160, 214, 166),
        highContrastDark: srgb(42, 112, 58)
    )
    static let deletionInline = adaptive(
        light: srgb(246, 204, 204),
        dark: srgb(104, 46, 46),
        highContrastLight: srgb(236, 170, 170),
        highContrastDark: srgb(140, 44, 44)
    )
    static let additionText = adaptive(
        light: srgb(46, 140, 62),
        dark: srgb(98, 190, 112),
        highContrastLight: srgb(15, 91, 37),
        highContrastDark: srgb(137, 234, 148)
    )
    static let deletionText = adaptive(
        light: srgb(207, 59, 59),
        dark: srgb(236, 112, 108),
        highContrastLight: srgb(157, 30, 30),
        highContrastDark: srgb(255, 156, 160)
    )

    static let statusAdded = additionText
    static let statusDeleted = deletionText
    static let statusModified = adaptive(light: srgb(145, 105, 56), dark: srgb(202, 167, 111))
    static let statusRenamed = readableStatusColor(NSColor.systemBlue)
    static let statusConflicted = readableStatusColor(NSColor.systemPurple)

    /// 侧栏里 worktree 相对上游领先或落后的计数。
    static let worktreeTracking = controlText

    /// Split 视图左右两栏之间的中缝。系统 separator 压在代码底色上看不出来，这里用标签色
    /// 淡淡混一层，浅色深色下都是一条能看见但不刺眼的灰线。
    static let splitPaneDivider = reviewDivider

    static let commitEdge0 = adaptive(light: srgb(130, 130, 130), dark: srgb(150, 150, 150))
    static let commitEdge1 = adaptive(
        light: srgb(142, 94, 237),
        dark: srgb(170, 124, 245)
    )
    static let commitEdge2 = adaptive(
        light: srgb(235, 71, 153),
        dark: srgb(242, 103, 172)
    )
    static let commitEdge3 = adaptive(
        light: srgb(255, 136, 0),
        dark: srgb(255, 165, 58)
    )
    static let commitEdge4 = adaptive(
        light: srgb(77, 191, 64),
        dark: srgb(111, 208, 101)
    )
    static let commitEdge5 = adaptive(
        light: srgb(0, 179, 179),
        dark: srgb(59, 205, 205)
    )

    // 语法色对齐 Claude Desktop：关键字和注解橙棕，类型名紫色，注释灰色，其余用正文色。
    // 字符串和数字用蓝青色，落在增删行的绿、红底上都还读得清。
    static let syntaxKeyword = adaptive(
        light: srgb(184, 92, 36),
        dark: srgb(232, 152, 98)
    )
    static let syntaxType = adaptive(
        light: srgb(130, 80, 200),
        dark: srgb(192, 154, 242)
    )
    static let syntaxString = adaptive(
        light: srgb(30, 104, 160),
        dark: srgb(122, 180, 230)
    )
    static let syntaxNumber = adaptive(
        light: srgb(18, 118, 138),
        dark: srgb(108, 198, 208)
    )
    static let syntaxComment = adaptive(
        light: srgb(150, 148, 140),
        dark: srgb(132, 130, 122)
    )
    static let syntaxHeading = syntaxKeyword

    private static func readableStatusColor(_ color: NSColor) -> NSColor {
        blended(
            foreground: color,
            background: NSColor.labelColor,
            fraction: 0.78
        )
    }

    private static let appearanceNames: [NSAppearance.Name] = [
        .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua
    ]

    private static func adaptive(
        light: NSColor, dark: NSColor,
        highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: appearanceNames) {
            case .accessibilityHighContrastDarkAqua: highContrastDark ?? dark
            case .accessibilityHighContrastAqua: highContrastLight ?? light
            case .darkAqua: dark
            default: light
            }
        }
    }

    private static func srgb(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        alpha: CGFloat = 1
    ) -> NSColor {
        NSColor(
            srgbRed: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: alpha
        )
    }

    private static func blended(
        foreground: NSColor,
        background: NSColor,
        fraction: CGFloat,
        darkFraction: CGFloat? = nil,
        highContrastFraction: CGFloat? = nil
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let name = appearance.bestMatch(from: appearanceNames)
            let resolvedFraction: CGFloat
            if name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua,
               let highContrastFraction {
                resolvedFraction = highContrastFraction
            } else if name == .darkAqua || name == .accessibilityHighContrastDarkAqua {
                resolvedFraction = darkFraction ?? fraction
            } else {
                resolvedFraction = fraction
            }
            var result = background
            appearance.performAsCurrentDrawingAppearance {
                result = background.blended(
                    withFraction: resolvedFraction,
                    of: foreground
                ) ?? background
            }
            return result
        }
    }
}
