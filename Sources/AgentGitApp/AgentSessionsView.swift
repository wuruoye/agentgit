import AgentGitCore
import AgentGitIntegrationShared
import SwiftUI

struct AgentSessionsButton: View {
    @Environment(AppModel.self) private var model

    let worktree: GitWorktree

    var body: some View {
        // 一个会话直接给按钮；多个会话时标题在工具栏里会全部被截成同样的前缀，改成一个下拉，
        // 菜单里才能看到完整标题和最近更新时间。
        Group {
            if sortedAssociations.count == 1, let association = sortedAssociations.first {
                shortcutButton(for: association)
            } else if sortedAssociations.count > 1 {
                Menu {
                    ForEach(sortedAssociations) { association in
                        Button {
                            model.agentAssociations.open(association)
                        } label: {
                            Text(association.menuTitle)
                        }
                    }
                    Divider()
                    ForEach(sortedAssociations) { association in
                        Button("Remove \(association.menuTitle)", role: .destructive) {
                            model.agentAssociations.remove(association)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(sortedAssociations.count) Sessions")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Agent sessions registered for this worktree")
                .accessibilityLabel(
                    "\(sortedAssociations.count) agent sessions for this worktree"
                )
            }
        }
    }

    private func shortcutButton(for association: AgentAssociation) -> some View {
        AgentSessionShortcutButton(
            association: association,
            availability: model.agentAssociations.navigationAvailability(
                for: association
            ),
            openSession: { model.agentAssociations.open(association) },
            removeSession: { model.agentAssociations.remove(association) }
        )
    }

    private var sortedAssociations: [AgentAssociation] {
        model.agentAssociations.associations(for: worktree)
    }
}

private struct AgentSessionShortcutButton: View {
    let association: AgentAssociation
    let availability: AgentSessionNavigationAvailability
    let openSession: () -> Void
    let removeSession: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: openSession) {
            HStack(spacing: 5) {
                Image(systemName: association.provider.systemImageName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tintColor)

                Text(compactAgentSessionTitle(association.displayTitle))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 124, minHeight: 28)
            .background(
                isHovered
                    ? Color(nsColor: AgentGitPalette.reviewHover)
                    : Color(nsColor: AgentGitPalette.reviewControlBackground),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tintColor.opacity(0.14), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(association.hoverDescription(availability: availability))
        .accessibilityLabel(
            "Open \(association.provider.displayName) session \(association.displayTitle)"
        )
        .contextMenu {
            Button("Open Session", action: openSession)
            Divider()
            Button("Remove Association", role: .destructive, action: removeSession)
        }
    }

    private var tintColor: Color {
        switch availability {
        case .resolving: .secondary
        case .available: association.provider.tintColor
        case .unavailable: .orange
        }
    }
}

func compactAgentSessionTitle(
    _ title: String,
    maximumCharacterCount: Int = 10
) -> String {
    let normalized = title
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    guard maximumCharacterCount > 0 else {
        return ""
    }
    guard normalized.count > maximumCharacterCount else {
        return normalized
    }
    guard maximumCharacterCount > 1 else {
        return "…"
    }
    return String(normalized.prefix(maximumCharacterCount - 1)) + "…"
}

private extension AgentAssociation {
    var displayTitle: String {
        title.isEmpty
            ? "\(provider.displayName) \(compactRelativeTime(updatedAt))"
            : title
    }

    /// 菜单里空间充足，标题不截断，用 provider 和更新时间把同名会话区分开。
    var menuTitle: String {
        let base = title.isEmpty ? "\(provider.displayName) Session" : title
        return "\(provider.displayName) · \(base) · \(compactRelativeTime(updatedAt))"
    }

    func hoverDescription(
        availability: AgentSessionNavigationAvailability
    ) -> String {
        let base = """
        \(displayTitle)
        \(provider.displayName) · \(sessionID)
        Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))
        """
        return switch availability {
        case .resolving:
            "\(base)\nChecking session availability…"
        case .available:
            base
        case let .unavailable(reason):
            "\(base)\n\(reason)"
        }
    }
}

extension AgentProvider {
    var systemImageName: String {
        switch self {
        case .codex:
            "terminal"
        case .claude:
            "sparkles"
        }
    }

    var tintColor: Color {
        switch self {
        case .codex:
            .blue
        case .claude:
            .orange
        }
    }
}
