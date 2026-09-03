import AppKit

enum AgentGitTypography {
    static let interfaceSize: CGFloat = 12
    static let codeSize: CGFloat = 12
    static var code: NSFont {
        NSFont(name: "Menlo", size: codeSize)
            ?? NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    }
    static var codeEmphasized: NSFont {
        NSFontManager.shared.convert(code, toHaveTrait: .boldFontMask)
    }
}

enum AgentGitPalette {
    static let canvas = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.22
    )
    static let chrome = NSColor.controlBackgroundColor
    static let selectedChrome = NSColor.windowBackgroundColor
    static let inputBackground = blended(
        foreground: NSColor.textBackgroundColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.62
    )
    static let imagePanel = NSColor.controlBackgroundColor
    static let imageChecker = blended(
        foreground: NSColor.quaternaryLabelColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.08
    )
    static let activeControl = NSColor.labelColor
    static let sidebarBackground = NSColor.windowBackgroundColor
    static let sidebarCardBackground = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.74
    )
    static let sidebarCardBorder = blended(
        foreground: NSColor.separatorColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.58
    )
    static let sidebarChrome = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.7
    )
    static let sidebarInputBackground = blended(
        foreground: NSColor.textBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.82
    )
    static let sidebarHover = blended(
        foreground: NSColor.labelColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.055
    )
    static let sidebarGroupHeader = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.58
    )
    static let sidebarSelection = blended(
        foreground: NSColor.systemBlue,
        background: NSColor.windowBackgroundColor,
        fraction: 0.075
    )
    static let sidebarSelectionBorder = NSColor.systemBlue
    static let sidebarMetadata = NSColor.secondaryLabelColor
    static let sidebarDivider = blended(
        foreground: NSColor.separatorColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.62
    )
    static let reviewChrome = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.82
    )
    static let reviewNavigationBackground = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.62
    )
    static let reviewTabBarBackground = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.76
    )
    static let reviewHeaderBorder = blended(
        foreground: NSColor.separatorColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.64
    )
    static let reviewControlBackground = blended(
        foreground: NSColor.textBackgroundColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.58
    )
    static let reviewControlBorder = blended(
        foreground: NSColor.separatorColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.62
    )
    static let reviewHover = blended(
        foreground: NSColor.labelColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.065
    )
    static let reviewHunkText = NSColor.labelColor
    static let reviewContextGap = adaptive(
        light: srgb(247, 250, 252),
        dark: srgb(35, 40, 45)
    )
    static let reviewContextGapText = adaptive(
        light: srgb(117, 124, 131),
        dark: srgb(139, 146, 153)
    )
    static let reviewActionBackground = blended(
        foreground: NSColor.labelColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.095
    )
    static let reviewActionConfirmationBackground = adaptive(
        light: srgb(255, 233, 231),
        dark: srgb(76, 41, 40)
    )
    static let reviewActionConfirmationText = adaptive(
        light: srgb(181, 46, 44),
        dark: srgb(255, 133, 130)
    )
    static let commitCountBackground = blended(
        foreground: NSColor.labelColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.075
    )
    static let commitPrimaryText = adaptive(
        light: srgb(4, 4, 4),
        dark: srgb(232, 232, 232)
    )
    static let commitSecondaryText = adaptive(
        light: srgb(112, 112, 112),
        dark: srgb(166, 166, 166)
    )
    static let groupHeader = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.68
    )
    static let folderHeader = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.78
    )
    static let fileListRow = blended(
        foreground: NSColor.controlBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.56
    )
    static let fileHeader = blended(
        foreground: NSColor.systemBlue,
        background: NSColor.controlBackgroundColor,
        fraction: 0.08
    )
    static let fileHeaderFocused = blended(
        foreground: NSColor.systemBlue,
        background: NSColor.controlBackgroundColor,
        fraction: 0.14
    )
    static let fileHeaderBoundary = blended(
        foreground: NSColor.systemBlue,
        background: NSColor.separatorColor,
        fraction: 0.38
    )
    static let fileContext = adaptive(
        light: srgb(251, 251, 252),
        dark: srgb(34, 34, 37)
    )
    static let hunkHeader = blended(
        foreground: NSColor.systemBlue,
        background: NSColor.textBackgroundColor,
        fraction: 0.055
    )
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
        light: srgb(242, 243, 244),
        dark: srgb(41, 42, 45)
    )
    static let separator = blended(
        foreground: NSColor.separatorColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.58
    )

    static let additionBackground = blended(
        foreground: adaptive(
            light: srgb(229, 248, 226),
            dark: srgb(38, 59, 41)
        ),
        background: NSColor.textBackgroundColor,
        fraction: 1
    )
    static let deletionBackground = blended(
        foreground: adaptive(
            light: srgb(248, 226, 226),
            dark: srgb(66, 40, 40)
        ),
        background: NSColor.textBackgroundColor,
        fraction: 1
    )
    static let metadataBackground = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.24
    )
    static let additionInline = blended(
        foreground: adaptive(
            light: srgb(196, 240, 194),
            dark: srgb(48, 82, 51)
        ),
        background: NSColor.textBackgroundColor,
        fraction: 1
    )
    static let deletionInline = blended(
        foreground: adaptive(
            light: srgb(240, 194, 194),
            dark: srgb(91, 49, 49)
        ),
        background: NSColor.textBackgroundColor,
        fraction: 1
    )
    static let additionText = adaptive(
        light: srgb(61, 153, 51),
        dark: srgb(111, 208, 101)
    )
    static let deletionText = adaptive(
        light: srgb(255, 0, 0),
        dark: srgb(255, 110, 110)
    )

    static let statusAdded = readableStatusColor(NSColor.systemGreen)
    static let statusDeleted = readableStatusColor(NSColor.systemRed)
    static let statusModified = readableStatusColor(NSColor.systemOrange)
    static let statusRenamed = readableStatusColor(NSColor.systemBlue)
    static let statusConflicted = readableStatusColor(NSColor.systemPurple)

    /// 侧栏里 worktree 相对上游领先或落后的计数。属于提示信息，不是警告，所以用蓝色。
    static let worktreeTracking = readableStatusColor(NSColor.systemBlue)

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

    static let syntaxKeyword = adaptive(
        light: srgb(198, 149, 198),
        dark: srgb(198, 149, 198)
    )
    static let syntaxString = adaptive(
        light: srgb(128, 185, 121),
        dark: srgb(153, 204, 150)
    )
    static let syntaxNumber = adaptive(
        light: srgb(249, 174, 88),
        dark: srgb(249, 184, 113)
    )
    static let syntaxComment = adaptive(
        light: srgb(153, 153, 153),
        dark: srgb(142, 149, 155)
    )
    static let syntaxHeading = adaptive(
        light: srgb(249, 123, 88),
        dark: srgb(240, 126, 132)
    )

    private static func readableStatusColor(_ color: NSColor) -> NSColor {
        blended(
            foreground: color,
            background: NSColor.labelColor,
            fraction: 0.78
        )
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
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
        fraction: CGFloat
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = background
            appearance.performAsCurrentDrawingAppearance {
                result = background.blended(
                    withFraction: fraction,
                    of: foreground
                ) ?? background
            }
            return result
        }
    }
}
