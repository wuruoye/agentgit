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
    // 参照 Workboard 的层次：`windowBackgroundColor` 作页面底，`controlBackgroundColor` 作卡片，
    // 卡片描边一律 `secondary.opacity(0.08)` 级别，圆角 11。AgentGit 原来把两者混成一个中间灰，
    // 结果页面和卡片分不开，整体发闷。

    /// 卡片和代码区之外的页面底色。
    static let canvas = NSColor.windowBackgroundColor
    /// 浮在页面底上的卡片。
    static let card = NSColor.controlBackgroundColor
    /// 卡片描边。
    static let cardBorder = blended(
        foreground: NSColor.secondaryLabelColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.08
    )
    /// 卡片圆角。小控件用 7，色调竖条用 2。
    static let cardCornerRadius: CGFloat = 11
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
    /// 展开的文件标题。原来是浅蓝，配上默认展开之后每个文件头都在跳蓝色；
    /// 蓝色留给当前聚焦的那一个，其余用中性浅灰。
    static let fileHeader = blended(
        foreground: NSColor.labelColor,
        background: NSColor.controlBackgroundColor,
        fraction: 0.055
    )
    static let fileHeaderFocused = blended(
        foreground: NSColor.systemBlue,
        background: NSColor.controlBackgroundColor,
        fraction: 0.14
    )
    static let fileHeaderBoundary = blended(
        foreground: NSColor.labelColor,
        background: NSColor.separatorColor,
        fraction: 0.22
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
    /// 代码区底色。之前跟着窗口用 `canvas`（灰），整片 diff 看起来是脏的，绿红色带也被
    /// 衬得过跳。代码应该坐在纯白/纯黑上，语法高亮和增删色带才有正常的对比。
    static let codeBackground = NSColor.textBackgroundColor

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
    /// 跨行选区底色。系统选中色直接铺满会盖掉增删色带，压一点透明度让行底色透出来。
    static let codeSelection = NSColor.selectedTextBackgroundColor
        .withAlphaComponent(0.7)
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
