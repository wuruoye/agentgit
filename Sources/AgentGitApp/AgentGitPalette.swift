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
    static let canvas = adaptive(
        light: srgb(252, 253, 253),
        dark: srgb(30, 31, 33)
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
    static let sidebarBackground = adaptive(
        light: srgb(246, 246, 248),
        dark: srgb(39, 39, 42)
    )
    static let sidebarChrome = adaptive(
        light: srgb(239, 239, 241),
        dark: srgb(47, 47, 50)
    )
    static let sidebarInputBackground = adaptive(
        light: srgb(253, 253, 253),
        dark: srgb(31, 31, 33)
    )
    static let sidebarHover = adaptive(
        light: srgb(233, 233, 236),
        dark: srgb(52, 52, 56)
    )
    static let sidebarGroupHeader = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.14
    )
    static let sidebarSelection = adaptive(
        light: srgb(213, 230, 249),
        dark: srgb(33, 59, 89)
    )
    static let sidebarSelectionBorder = NSColor.systemBlue
    static let sidebarMetadata = NSColor.secondaryLabelColor
    static let sidebarDivider = adaptive(
        light: srgb(60, 60, 67, alpha: 0.18),
        dark: srgb(235, 235, 245, alpha: 0.11)
    )
    static let reviewChrome = adaptive(
        light: srgb(199, 204, 209),
        dark: srgb(43, 43, 46)
    )
    static let reviewNavigationBackground = adaptive(
        light: srgb(236, 237, 239),
        dark: srgb(37, 38, 41)
    )
    static let reviewTabBarBackground = adaptive(
        light: srgb(199, 204, 209),
        dark: srgb(48, 50, 54)
    )
    static let reviewHeaderBorder = adaptive(
        light: srgb(217, 217, 220),
        dark: srgb(57, 57, 61)
    )
    static let reviewControlBackground = adaptive(
        light: srgb(236, 237, 239),
        dark: srgb(48, 48, 51)
    )
    static let reviewControlBorder = adaptive(
        light: srgb(173, 179, 184),
        dark: srgb(71, 71, 75)
    )
    static let reviewHover = adaptive(
        light: srgb(229, 229, 232),
        dark: srgb(59, 59, 63)
    )
    static let reviewHunkText = adaptive(
        light: srgb(64, 64, 64),
        dark: srgb(141, 182, 221)
    )
    static let reviewContextGap = adaptive(
        light: srgb(247, 250, 252),
        dark: srgb(35, 40, 45)
    )
    static let reviewContextGapText = adaptive(
        light: srgb(117, 124, 131),
        dark: srgb(139, 146, 153)
    )
    static let reviewActionBackground = adaptive(
        light: srgb(173, 179, 184),
        dark: srgb(72, 77, 82)
    )
    static let reviewActionConfirmationBackground = adaptive(
        light: srgb(255, 233, 231),
        dark: srgb(76, 41, 40)
    )
    static let reviewActionConfirmationText = adaptive(
        light: srgb(181, 46, 44),
        dark: srgb(255, 133, 130)
    )
    static let commitCountBackground = adaptive(
        light: srgb(211, 214, 217),
        dark: srgb(74, 77, 81)
    )
    static let commitPrimaryText = adaptive(
        light: srgb(4, 4, 4),
        dark: srgb(232, 232, 232)
    )
    static let commitSecondaryText = adaptive(
        light: srgb(112, 112, 112),
        dark: srgb(166, 166, 166)
    )
    static let commitSelection = adaptive(
        light: srgb(209, 224, 240),
        dark: srgb(45, 60, 76)
    )
    static let groupHeader = adaptive(
        light: srgb(246, 246, 247),
        dark: srgb(40, 40, 43)
    )
    static let folderHeader = adaptive(
        light: srgb(237, 239, 242),
        dark: srgb(43, 44, 47)
    )
    static let fileHeader = adaptive(
        light: srgb(186, 212, 238),
        dark: srgb(33, 47, 61)
    )
    static let fileHeaderFocused = adaptive(
        light: srgb(205, 225, 245),
        dark: srgb(38, 57, 76)
    )
    static let fileHeaderBoundary = adaptive(
        light: srgb(93, 146, 201, alpha: 0.42),
        dark: srgb(113, 165, 217, alpha: 0.46)
    )
    static let fileContext = adaptive(
        light: srgb(251, 251, 252),
        dark: srgb(34, 34, 37)
    )
    static let hunkHeader = adaptive(
        light: srgb(228, 237, 246),
        dark: srgb(32, 47, 62)
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
            dark: srgb(45, 82, 48)
        ),
        background: NSColor.textBackgroundColor,
        fraction: 1
    )
    static let deletionBackground = blended(
        foreground: adaptive(
            light: srgb(248, 226, 226),
            dark: srgb(87, 48, 48)
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
            dark: srgb(57, 103, 60)
        ),
        background: NSColor.textBackgroundColor,
        fraction: 1
    )
    static let deletionInline = blended(
        foreground: adaptive(
            light: srgb(240, 194, 194),
            dark: srgb(112, 59, 59)
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
