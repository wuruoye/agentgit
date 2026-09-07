import AppKit
import SwiftUI

@MainActor
enum ReviewIcon: String, CaseIterable {
    case stage, unstage, review, reviewed, expand, collapse, discard, more
    case display, split, unified, focus, history, refresh, previous, next, close

    private static var cache: [ReviewIcon: NSImage] = [:]
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
        let image = resourceURL.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }

    private var fallbackSymbol: String {
        switch self {
        case .stage: "plus.circle"
        case .unstage: "minus.circle"
        case .review: "circle"
        case .reviewed: "checkmark.circle"
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
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: icon.image)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum ReviewControlKind { case normal, selected, primary }

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

    private var fill: Color {
        if kind == .primary { return .accentColor }
        if kind == .selected { return .accentColor.opacity(configuration.isPressed ? 0.2 : 0.11) }
        return Color(nsColor: configuration.isPressed ? AgentGitPalette.inputBackground : isHovered ? AgentGitPalette.reviewHover : AgentGitPalette.card)
    }

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(kind == .primary ? Color.white : kind == .selected ? Color.accentColor : Color.primary)
            .padding(.horizontal, iconOnly ? 7 : 10)
            .frame(minWidth: 30, minHeight: 30)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(kind == .normal ? Color(nsColor: AgentGitPalette.reviewControlBorder).opacity(isHovered ? 1 : 0.7) : Color.clear, lineWidth: 0.7)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
