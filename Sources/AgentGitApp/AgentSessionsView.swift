import AgentGitCore
import AgentGitIntegrationShared
import SwiftUI

struct AgentSessionsButton: View {
    @Environment(AppModel.self) private var model

    let worktree: GitWorktree

    var body: some View {
        HStack(spacing: 5) {
            ForEach(sortedAssociations) { association in
                AgentSessionShortcutButton(
                    association: association,
                    availability: model.agentAssociations.navigationAvailability(
                        for: association
                    ),
                    openSession: { model.agentAssociations.open(association) },
                    removeSession: { model.agentAssociations.remove(association) }
                )
            }
        }
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

    var body: some View {
        Button(action: openSession) {
            HStack(spacing: 5) {
                Image(systemName: association.provider.systemImageName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tintColor)

                Text(compactAgentSessionTitle(association.displayTitle))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 112, minHeight: 26)
            .background(
                Color(nsColor: AgentGitPalette.reviewControlBackground),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: AgentGitPalette.reviewControlBorder))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
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
        title.isEmpty ? "\(provider.displayName) Session" : title
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
