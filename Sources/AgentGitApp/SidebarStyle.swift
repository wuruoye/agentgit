import AppKit
import SwiftUI

enum SidebarStyle {
    static let bodySize: CGFloat = 16
    static let titleSize: CGFloat = 15.7
    static let projectTitleSize: CGFloat = 15.5
    static let detailSize: CGFloat = 14.5
    static let navigationHeight: CGFloat = 32
    static let singleLineWorktreeHeight: CGFloat = 36
    static let worktreeHeight: CGFloat = 60
    static let worktreeVerticalInset: CGFloat = 6.5
    static let groupHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 7
    static let rowInset: CGFloat = 9.5
    static let rowTrailingInset: CGFloat = 12.5
    static let textInset: CGFloat = 22
    static let rowContentInset = textInset - rowInset

    static func font(_ size: CGFloat) -> Font {
        .agentGitInterface(size: size, weight: .light)
    }

    static let background = color(0xFAF9F7, dark: 0x1C1C1C)
    static let searchBackground = color(0xFDFDFB, dark: 0x262626)
    static let searchBorder = color(0xDFDFDD, dark: 0x3D3D3D)
    static let primary = color(0x41403D, dark: 0xD6D5D1)
    static let secondary = color(0x76746E, dark: 0x99978F)
    static let selectedText = color(0x0B0B0B, dark: 0xFAF9F7)
    static let selection = color(0xEDEBE7, dark: 0x34332F)
    static let hover = color(0xF1F0EC, dark: 0x2B2A27)
    static let newIconBackground = color(0xE5E4DD, dark: 0x35342F)

    private static func color(_ light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    var isSelected = false
    var showsPressedState = true

    func makeBody(configuration: Configuration) -> some View {
        SidebarRowButtonBody(configuration: configuration, isSelected: isSelected, showsPressedState: showsPressedState)
    }
}

private struct SidebarRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let showsPressedState: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: SidebarStyle.cornerRadius)
                        .fill(Color(nsColor: SidebarStyle.selection))
                        .opacity(isSelected ? 1 : 0)
                    RoundedRectangle(cornerRadius: SidebarStyle.cornerRadius)
                        .fill(Color(nsColor: SidebarStyle.hover))
                        .opacity(isEnabled && !isSelected && isHighlighted ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHighlighted)
                }
                .animation(nil, value: isSelected)
                .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: SidebarStyle.cornerRadius))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                isHovered = false
            }
    }

    private var isHighlighted: Bool {
        isHovered || (showsPressedState && configuration.isPressed)
    }
}

struct SidebarNavigationLabel: View {
    let title: String
    let icon: SidebarIcon.Kind
    var isNew = false
    var isSelected = false

    var body: some View {
        HStack(spacing: 9) {
            SidebarIcon(kind: icon)
                .frame(width: 16, height: 16)
                .frame(width: 21, height: 21)
                .background {
                    if isNew {
                        Circle().fill(Color(nsColor: SidebarStyle.newIconBackground))
                            .frame(width: 22, height: 22)
                    }
                }
            Text(title)
                .font(SidebarStyle.font(SidebarStyle.bodySize))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(nsColor: isSelected ? SidebarStyle.selectedText : SidebarStyle.primary))
        .padding(.leading, 20.5 - SidebarStyle.rowInset)
        .padding(.trailing, 16 - SidebarStyle.rowTrailingInset)
        .frame(height: SidebarStyle.navigationHeight)
    }
}

/// 与侧栏样板共用图标轮廓和线宽，文字起点不随 SF Symbols 字形变化。
struct SidebarIcon: View {
    enum Kind { case search, plus, projects, worktrees, briefcase, more }
    let kind: Kind

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                switch kind {
                case .search:
                    path.addEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
                    path.move(to: CGPoint(x: 16, y: 16))
                    path.addLine(to: CGPoint(x: 23, y: 23))
                case .plus:
                    path.move(to: CGPoint(x: 5, y: 12))
                    path.addLine(to: CGPoint(x: 19, y: 12))
                    path.move(to: CGPoint(x: 12, y: 5))
                    path.addLine(to: CGPoint(x: 12, y: 19))
                case .projects:
                    path.move(to: CGPoint(x: 6, y: 3))
                    path.addLine(to: CGPoint(x: 18, y: 3))
                    path.move(to: CGPoint(x: 3, y: 8))
                    path.addLine(to: CGPoint(x: 21, y: 8))
                    path.addLine(to: CGPoint(x: 19, y: 21))
                    path.addLine(to: CGPoint(x: 5, y: 21))
                    path.closeSubpath()
                case .worktrees:
                    path.addRoundedRect(in: CGRect(x: 13, y: 10, width: 8, height: 10), cornerSize: CGSize(width: 1, height: 1))
                    path.addEllipse(in: CGRect(x: 2, y: 14, width: 7, height: 7))
                    path.move(to: CGPoint(x: 5, y: 14))
                    path.addLine(to: CGPoint(x: 5, y: 6))
                    path.addCurve(to: CGPoint(x: 13, y: 3), control1: CGPoint(x: 5, y: 1), control2: CGPoint(x: 11, y: 1))
                    path.addLine(to: CGPoint(x: 18, y: 6))
                    path.addLine(to: CGPoint(x: 7, y: 15))
                case .briefcase:
                    path.addRoundedRect(in: CGRect(x: 2, y: 7, width: 20, height: 15), cornerSize: CGSize(width: 2, height: 2))
                    path.addRoundedRect(in: CGRect(x: 7, y: 3, width: 10, height: 5), cornerSize: CGSize(width: 2, height: 2))
                    path.move(to: CGPoint(x: 2, y: 12))
                    path.addLine(to: CGPoint(x: 22, y: 12))
                case .more:
                    for x: CGFloat in [4, 12, 20] {
                        path.addEllipse(in: CGRect(x: x - 0.8, y: 11.2, width: 1.6, height: 1.6))
                    }
                }
            }
            .applying(CGAffineTransform(scaleX: geometry.size.width / 24, y: geometry.size.height / 24))
            .stroke(style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
