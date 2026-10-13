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
                    let removable = sortedAssociations.filter { $0.id != creator?.id }
                    if !removable.isEmpty {
                        Divider()
                        ForEach(removable) { association in
                            Button("Remove \(association.menuTitle)", role: .destructive) {
                                model.agentAssociations.remove(association)
                            }
                        }
                    }
                } label: {
                    Label("\(sortedAssociations.count) Sessions", systemImage: "sparkles")
                }
                .menuStyle(.automatic)
                .labelStyle(.titleAndIcon)
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
            isCreator: association.id == creator?.id,
            openSession: { model.agentAssociations.open(association) },
            removeSession: association.id == creator?.id
                ? nil
                : { model.agentAssociations.remove(association) }
        )
    }

    /// 创建这个 worktree 的会话排在最前；创建者记录不能在这里移除。
    private var creator: AgentAssociation? {
        model.agentAssociations.creatorAssociation(forWorktreeAt: worktree.id)
    }

    private var sortedAssociations: [AgentAssociation] {
        let stored = model.agentAssociations.associations(for: worktree)
        let associations = creator.map { creator in
            [creator] + stored.filter { $0.id != creator.id }
        } ?? stored
        // 标题优先用宿主里的最新标题。
        return associations.map { association in
            AgentAssociation(
                provider: association.provider,
                sessionID: association.sessionID,
                worktreePath: association.worktreePath,
                title: model.agentAssociations.displayTitle(for: association),
                updatedAt: association.updatedAt
            )
        }
    }
}

private struct AgentSessionShortcutButton: View {
    let association: AgentAssociation
    let availability: AgentSessionNavigationAvailability
    let isCreator: Bool
    let openSession: () -> Void
    let removeSession: (() -> Void)?

    var body: some View {
        Button(action: openSession) {
            Label(
                "\(association.provider.displayName) Session",
                systemImage: association.provider.systemImageName
            )
            .foregroundStyle(tintColor)
            .lineLimit(1)
        }
        .buttonStyle(.automatic)
        .labelStyle(.titleAndIcon)
        .help(
            (isCreator ? "Created this worktree\n" : "")
                + association.hoverDescription(availability: availability)
        )
        .accessibilityLabel(
            "Open \(association.provider.displayName) session \(association.displayTitle)"
        )
        .contextMenu {
            Button("Open Session", action: openSession)
            if let removeSession {
                Divider()
                Button("Remove Association", role: .destructive, action: removeSession)
            }
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
            ? "\(provider.displayName) \(sessionID.prefix(8))"
            : title
    }

    /// 菜单里空间充足，标题不截断，用 provider 和更新时间把同名会话区分开。
    var menuTitle: String {
        let base = title.isEmpty ? String(sessionID.prefix(8)) : title
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
