import AgentGitCore
import AgentGitIntegrationShared
import AppKit
import SwiftUI
import XCTest
@testable import AgentGitApp

@MainActor
final class AgentSessionsViewTests: XCTestCase {
    func testCompactTitleUsesAtMostTenCharacters() {
        XCTAssertEqual(compactAgentSessionTitle("Short task"), "Short task")
        XCTAssertEqual(
            compactAgentSessionTitle("123456789012345"),
            "123456789…"
        )
        XCTAssertEqual(
            compactAgentSessionTitle("  多段   空白\n标题  "),
            "多段 空白 标题"
        )
        XCTAssertEqual(
            compactAgentSessionTitle("Long title", maximumCharacterCount: 1),
            "…"
        )
    }

    func testRendersAtMostThreeProviderShortcuts() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/agent-shortcuts-\(UUID().uuidString)",
            isDirectory: true
        )
        let associationURL = container.appendingPathComponent("associations.json")
        let auditURL = container.appendingPathComponent("registration-events.json")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let worktreeURL = container.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeURL,
            withIntermediateDirectories: true
        )
        let store = AgentAssociationStore(storeURL: associationURL)
        let titles = [
            "123456789012345",
            "Claude review",
            "Fix tests",
            "Hidden session"
        ]
        for (index, title) in titles.enumerated() {
            _ = try store.upsert(
                AgentAssociation(
                    provider: index.isMultiple(of: 2) ? .codex : .claude,
                    sessionID: "session-\(index)",
                    worktreePath: worktreeURL.path,
                    title: title,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(100 + index))
                )
            )
        }
        let controller = AgentAssociationController(
            store: store,
            auditStore: AgentRegistrationAuditStore(storeURL: auditURL)
        )
        controller.refresh()
        controller.setApplicationActive(false)
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            agentAssociations: controller
        )
        model.setApplicationActive(false)
        let worktree = GitWorktree(
            rootURL: worktreeURL,
            headOID: String(repeating: "a", count: 40),
            branchRef: "refs/heads/main",
            isBare: false,
            isDetached: false,
            lockedReason: nil,
            prunableReason: nil
        )
        let storedAssociations = controller.associations(for: worktree)
        XCTAssertEqual(storedAssociations.count, 3)
        XCTAssertFalse(storedAssociations.contains { $0.title == titles[0] })
        let size = NSSize(width: 360, height: 52)
        let hostingView = NSHostingView(
            rootView: AgentSessionsButton(worktree: worktree)
                .environment(model)
                .padding(8)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.width, 280)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.width, size.width)
        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, size.height)

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        try png.write(
            to: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            ).appendingPathComponent(
                ".build/verification/AgentGitAgentSessions-shortcuts.png"
            )
        )
    }

}
