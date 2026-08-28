import AgentGitCore
import AgentGitIntegrationShared
import SwiftUI

struct AgentSessionsButton: View {
    @Environment(AppModel.self) private var model
    @State private var isMorePresented = false

    let worktree: GitWorktree

    var body: some View {
        let associations = sortedAssociations
        let visibleAssociations = Array(associations.prefix(3))
        let remainingAssociations = Array(associations.dropFirst(3))

        HStack(spacing: 5) {
            ForEach(visibleAssociations) { association in
                AgentSessionShortcutButton(
                    association: association,
                    availability: model.agentAssociations.navigationAvailability(
                        for: association
                    ),
                    openSession: { model.agentAssociations.open(association) },
                    removeSession: { model.agentAssociations.remove(association) }
                )
            }

            if !remainingAssociations.isEmpty {
                Button {
                    isMorePresented.toggle()
                } label: {
                    Text("+\(remainingAssociations.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(.quaternary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(
                    "Show " + countedLabel(
                        remainingAssociations.count,
                        singular: "more agent session",
                        plural: "more agent sessions"
                    )
                )
                .accessibilityLabel("Show more registered agent sessions")
                .popover(isPresented: $isMorePresented, arrowEdge: .bottom) {
                    MoreAgentSessionsPopover(
                        associations: remainingAssociations,
                        navigationAvailability: model.agentAssociations.navigationAvailability,
                        openSession: { association in
                            isMorePresented = false
                            model.agentAssociations.open(association)
                        },
                        removeSession: model.agentAssociations.remove
                    )
                }
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tintColor)

                Text(compactAgentSessionTitle(association.displayTitle))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 24)
            .background(
                tintColor.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tintColor.opacity(0.18))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
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

private struct MoreAgentSessionsPopover: View {
    let associations: [AgentAssociation]
    let navigationAvailability: (
        AgentAssociation
    ) -> AgentSessionNavigationAvailability
    let openSession: (AgentAssociation) -> Void
    let removeSession: (AgentAssociation) -> Void

    private var preferredHeight: CGFloat {
        min(58 + CGFloat(associations.count * 62), 420)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("More Agent Sessions")
                    .font(.headline)
                Spacer(minLength: 12)
                Text("\(associations.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(associations) { association in
                        AgentSessionCard(
                            association: association,
                            availability: navigationAvailability(association),
                            openSession: { openSession(association) },
                            removeSession: { removeSession(association) }
                        )
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 400, height: preferredHeight)
    }
}

private struct AgentSessionCard: View {
    let association: AgentAssociation
    let availability: AgentSessionNavigationAvailability
    let openSession: () -> Void
    let removeSession: () -> Void

    var body: some View {
        Button(action: openSession) {
            HStack(spacing: 9) {
                Image(systemName: association.provider.systemImageName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(association.provider.tintColor)
                    .frame(width: 28, height: 28)
                    .background(
                        association.provider.tintColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 7)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(association.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(association.provider.displayName)
                            .foregroundStyle(association.provider.tintColor)
                        Text(String(association.sessionID.prefix(8)))
                            .font(.caption.monospaced())
                        Text("·")
                        Text(compactRelativeTime(association.updatedAt))
                            .monospacedDigit()
                        if case .unavailable = availability {
                            Text("Unavailable")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(association.provider.tintColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(
                association.provider.tintColor.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(association.provider.tintColor.opacity(0.16))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(association.hoverDescription(availability: availability))
        .contextMenu {
            Button("Open Session", action: openSession)
            Divider()
            Button("Remove Association", role: .destructive, action: removeSession)
        }
    }
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
