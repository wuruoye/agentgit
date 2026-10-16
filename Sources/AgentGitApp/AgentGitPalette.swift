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
    static let codeBackground = NSColor.textBackgroundColor
    static let reviewContextGap = adaptive(light: srgb(245, 247, 251), dark: srgb(30, 35, 43))
    static let reviewContextGapText = adaptive(light: srgb(114, 126, 145), dark: srgb(141, 154, 175))
    static let fileHeader = card
    static let fileContext = adaptive(light: srgb(249, 249, 249), dark: srgb(32, 32, 32))
    static let hunkHeader = adaptive(light: srgb(252, 252, 252), dark: srgb(39, 39, 39))
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
    static let reviewNavigationBackground = canvas
    static let reviewTabBarBackground = canvas
    static let reviewHeaderBorder = cardBorder
    static let reviewControlBackground = card
    static let reviewControlBorder = cardBorder
    static let reviewHover = controlHover
    static let reviewHunkText = commitPrimaryText
    static let reviewActionBackground = inputBackground
    static let commitCountBackground = inputBackground
    static let groupHeader = card
    static let folderHeader = inputBackground
    static let fileListRow = card
    static let fileHeaderBoundary = cardBorder
    static let sidebarSelection = adaptive(
        light: srgb(239, 239, 239), dark: srgb(55, 55, 55),
        highContrastLight: srgb(203, 203, 203), highContrastDark: srgb(86, 86, 86)
    )
    static let fileHeaderFocused = blended(foreground: activeControl, background: card, fraction: 0.045)

    static let codeText = adaptive(
        light: srgb(51, 51, 51),
        dark: srgb(215, 215, 215)
    )
    static let codeLineNumber = adaptive(
        light: srgb(153, 153, 153),
        dark: srgb(132, 132, 132)
    )
    static let codeGutter = adaptive(
        light: srgb(246, 247, 248),
        dark: srgb(38, 39, 42)
    )
    static let codeFiller = adaptive(
        light: srgb(247, 248, 250),
        dark: srgb(29, 33, 40)
    )
    /// 跨行选区底色。系统选中色直接铺满会盖掉增删色带，压一点透明度让行底色透出来。
    static let codeSelection = NSColor.selectedTextBackgroundColor
        .withAlphaComponent(0.7)
    static let separator = cardBorder

    static let additionBackground = blended(
        foreground: additionText,
        background: NSColor.textBackgroundColor,
        fraction: 0.10,
        darkFraction: 0.16,
        highContrastFraction: 0.22
    )
    static let deletionBackground = blended(
        foreground: deletionText,
        background: NSColor.textBackgroundColor,
        fraction: 0.10,
        darkFraction: 0.16,
        highContrastFraction: 0.22
    )
    static let metadataBackground = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.24
    )
    static let additionInline = blended(
        foreground: additionText,
        background: NSColor.textBackgroundColor,
        fraction: 0.28,
        darkFraction: 0.30,
        highContrastFraction: 0.40
    )
    static let deletionInline = blended(
        foreground: deletionText,
        background: NSColor.textBackgroundColor,
        fraction: 0.28,
        darkFraction: 0.30,
        highContrastFraction: 0.40
    )
    static let additionText = adaptive(
        light: srgb(35, 132, 87),
        dark: srgb(111, 208, 101),
        highContrastLight: srgb(15, 91, 49),
        highContrastDark: srgb(137, 234, 148)
    )
    static let deletionText = adaptive(
        light: srgb(192, 65, 78),
        dark: srgb(255, 110, 110),
        highContrastLight: srgb(157, 35, 47),
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
    static let splitPaneDivider = blended(
        foreground: NSColor.labelColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.22
    )

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

    // 浅色这一套原来直接沿用了深色主题的粉紫、淡绿、浅橙，压在白底上全是低对比，代码看着一片糊。
    // 字符串原来还是绿色，落在新增行的绿底上几乎读不出来，所以浅色下改成红棕，和增删底色错开。
    static let syntaxKeyword = adaptive(
        light: srgb(155, 35, 147),
        dark: srgb(198, 149, 198)
    )
    static let syntaxString = adaptive(
        light: srgb(184, 30, 26),
        dark: srgb(153, 204, 150)
    )
    static let syntaxNumber = adaptive(
        light: srgb(28, 60, 178),
        dark: srgb(249, 184, 113)
    )
    static let syntaxComment = adaptive(
        light: srgb(106, 115, 125),
        dark: srgb(142, 149, 155)
    )
    static let syntaxHeading = adaptive(
        light: srgb(178, 80, 26),
        dark: srgb(240, 126, 132)
    )

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
