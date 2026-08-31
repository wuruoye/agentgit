import AppKit

enum AgentGitPalette {
    static let canvas = NSColor.textBackgroundColor
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
    static let sidebarGroupHeader = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.14
    )
    static let sidebarSelection = blended(
        foreground: NSColor.controlAccentColor,
        background: NSColor.windowBackgroundColor,
        fraction: 0.11
    )
    static let sidebarSelectionBorder = NSColor.controlAccentColor
    static let sidebarMetadata = NSColor.secondaryLabelColor
    static let sidebarDirtyBadge = blended(
        foreground: NSColor.systemOrange,
        background: NSColor.windowBackgroundColor,
        fraction: 0.13
    )
    static let sidebarAdditionText = readableStatusColor(NSColor.systemGreen)
    static let sidebarDeletionText = readableStatusColor(NSColor.systemRed)

    static let groupHeader = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.22
    )
    static let fileHeader = blended(
        foreground: NSColor.controlAccentColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.13
    )
    static let fileHeaderFocused = blended(
        foreground: NSColor.controlAccentColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.19
    )
    static let fileContext = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.12
    )
    static let hunkHeader = blended(
        foreground: NSColor.controlAccentColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.07
    )
    static let codeGutter = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.13
    )
    static let codeFiller = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.2
    )
    static let separator = blended(
        foreground: NSColor.separatorColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.58
    )

    static let additionBackground = blended(
        foreground: NSColor.systemGreen,
        background: NSColor.textBackgroundColor,
        fraction: 0.095
    )
    static let deletionBackground = blended(
        foreground: NSColor.systemRed,
        background: NSColor.textBackgroundColor,
        fraction: 0.09
    )
    static let metadataBackground = blended(
        foreground: NSColor.unemphasizedSelectedContentBackgroundColor,
        background: NSColor.textBackgroundColor,
        fraction: 0.24
    )
    static let additionInline = blended(
        foreground: NSColor.systemGreen,
        background: NSColor.textBackgroundColor,
        fraction: 0.22
    )
    static let deletionInline = blended(
        foreground: NSColor.systemRed,
        background: NSColor.textBackgroundColor,
        fraction: 0.21
    )
    static let additionText = readableStatusColor(NSColor.systemGreen)
    static let deletionText = readableStatusColor(NSColor.systemRed)

    static let statusAdded = readableStatusColor(NSColor.systemGreen)
    static let statusDeleted = readableStatusColor(NSColor.systemRed)
    static let statusModified = readableStatusColor(NSColor.systemOrange)
    static let statusRenamed = readableStatusColor(NSColor.systemBlue)
    static let statusConflicted = readableStatusColor(NSColor.systemPurple)

    static let syntaxKeyword = NSColor.systemPurple
    static let syntaxString = NSColor.systemRed
    static let syntaxNumber = NSColor.systemBlue
    static let syntaxComment = readableStatusColor(NSColor.systemGreen)
    static let syntaxHeading = NSColor.systemBlue

    private static func readableStatusColor(_ color: NSColor) -> NSColor {
        blended(
            foreground: color,
            background: NSColor.labelColor,
            fraction: 0.78
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
