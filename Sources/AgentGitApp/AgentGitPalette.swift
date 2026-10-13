import AppKit

enum AgentGitTypography {
    static let interfaceSize: CGFloat = 13
    static let codeSize: CGFloat = 13
    static var code: NSFont {
        NSFont(name: "Menlo", size: codeSize)
            ?? NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    }
    static var codeEmphasized: NSFont {
        NSFontManager.shared.convert(code, toHaveTrait: .boldFontMask)
    }
}

enum AgentGitPalette {
    static let cardCornerRadius: CGFloat = 10
    static let canvas = adaptive(light: srgb(244, 246, 249), dark: srgb(24, 27, 33))
    static let card = adaptive(light: srgb(255, 255, 255), dark: srgb(31, 35, 43))
    static let cardBorder = adaptive(light: srgb(224, 229, 236), dark: srgb(48, 54, 65))
    static let sidebarBackground = adaptive(light: srgb(239, 242, 247), dark: srgb(22, 25, 31))
    static let inputBackground = adaptive(light: srgb(232, 237, 244), dark: srgb(37, 42, 52))
    static let sidebarHover = adaptive(light: srgb(228, 234, 243), dark: srgb(37, 43, 54))
    static let codeBackground = adaptive(light: srgb(255, 255, 255), dark: srgb(27, 31, 38))
    static let reviewContextGap = adaptive(light: srgb(245, 247, 251), dark: srgb(30, 35, 43))
    static let reviewContextGapText = adaptive(light: srgb(114, 126, 145), dark: srgb(141, 154, 175))
    static let fileHeader = adaptive(light: srgb(248, 250, 253), dark: srgb(33, 38, 47))
    static let fileContext = adaptive(light: srgb(249, 250, 253), dark: srgb(29, 33, 41))
    static let hunkHeader = adaptive(light: srgb(244, 247, 251), dark: srgb(30, 35, 43))
    static let reviewActionConfirmationBackground = adaptive(light: srgb(255, 234, 234), dark: srgb(76, 41, 40))
    static let reviewActionConfirmationText = adaptive(light: srgb(181, 46, 44), dark: srgb(255, 133, 130))
    static let commitPrimaryText = adaptive(light: srgb(32, 40, 53), dark: srgb(231, 236, 245))
    static let commitSecondaryText = adaptive(light: srgb(88, 102, 121), dark: srgb(172, 183, 201))
    static let chrome = card
    static let selectedChrome = canvas
    static let imagePanel = card
    static let imageChecker = inputBackground
    static let activeControl = NSColor.labelColor
    static let sidebarCardBackground = sidebarBackground
    static let sidebarCardBorder = cardBorder
    static let sidebarChrome = sidebarBackground
    static let sidebarInputBackground = card
    static let sidebarGroupHeader = sidebarBackground
    static let sidebarSelectionBorder = NSColor.controlAccentColor
    static let sidebarMetadata = commitSecondaryText
    static let sidebarDivider = cardBorder
    static let reviewChrome = card
    static let reviewNavigationBackground = card
    static let reviewTabBarBackground = canvas
    static let reviewHeaderBorder = cardBorder
    static let reviewControlBackground = card
    static let reviewControlBorder = cardBorder
    static let reviewHover = sidebarHover
    static let reviewHunkText = commitPrimaryText
    static let reviewActionBackground = inputBackground
    static let commitCountBackground = inputBackground
    static let groupHeader = canvas
    static let folderHeader = canvas
    static let fileListRow = card
    static let fileHeaderBoundary = cardBorder
    static let sidebarSelection = blended(foreground: .controlAccentColor, background: sidebarBackground, fraction: 0.12)
    static let fileHeaderFocused = blended(foreground: .controlAccentColor, background: card, fraction: 0.055)

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
    static let separator = blended(
        foreground: NSColor.separatorColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.58
    )

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
    static let statusModified = readableStatusColor(NSColor.systemOrange)
    static let statusRenamed = readableStatusColor(NSColor.systemBlue)
    static let statusConflicted = readableStatusColor(NSColor.systemPurple)

    /// 侧栏里 worktree 相对上游领先或落后的计数。属于提示信息，不是警告，所以用蓝色。
    static let worktreeTracking = readableStatusColor(NSColor.systemBlue)

    /// Split 视图左右两栏之间的中缝。系统 separator 压在代码底色上看不出来，这里用标签色
    /// 淡淡混一层，浅色深色下都是一条能看见但不刺眼的灰线。
    static let splitPaneDivider = blended(
        foreground: NSColor.labelColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.22
    )

    static let commitEdge0 = adaptive(
        light: srgb(51, 153, 255),
        dark: srgb(93, 173, 255)
    )
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
