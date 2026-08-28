import AgentGitIntegrationShared
import AppKit
import SwiftUI
import XCTest
@testable import AgentGitApp

@MainActor
final class AgentGitSettingsViewTests: XCTestCase {
    func testRendersSettingsSectionsInLightAndDarkAppearancesOffscreen() async throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        model.setApplicationActive(false)

        try await render(
            AgentGitSettingsView(initialSection: .review).environment(model),
            appearance: .aqua,
            fileName: "AgentGitSettings-review-light.png",
            size: NSSize(width: 560, height: 280)
        )
        try await render(
            AgentGitSettingsView(initialSection: .review).environment(model),
            appearance: .darkAqua,
            fileName: "AgentGitSettings-review-dark.png",
            size: NSSize(width: 560, height: 280)
        )
        try await render(
            AgentGitSettingsView(initialSection: .agents).environment(model),
            appearance: .aqua,
            fileName: "AgentGitSettings-agents-light.png",
            size: NSSize(width: 560, height: 540)
        )
        try await render(
            AgentGitSettingsView(initialSection: .agents).environment(model),
            appearance: .darkAqua,
            fileName: "AgentGitSettings-agents-dark.png",
            size: NSSize(width: 560, height: 540)
        )
    }

    func testRendersAgentStorageRepairStateOffscreen() async throws {
        let container = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(
            ".build/test-repositories/settings-storage-repair-\(UUID().uuidString)",
            isDirectory: true
        )
        let associationURL = container.appendingPathComponent("associations.json")
        let auditURL = container.appendingPathComponent("registration-events.json")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        try Data("{invalid".utf8).write(to: associationURL)
        try Data("[invalid".utf8).write(to: auditURL)
        let controller = AgentAssociationController(
            store: AgentAssociationStore(storeURL: associationURL),
            auditStore: AgentRegistrationAuditStore(storeURL: auditURL)
        )
        controller.refresh()
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            agentAssociations: controller
        )
        model.setApplicationActive(false)

        try await render(
            AgentGitSettingsView(
                contentHeight: 620,
                initialSection: .agents
            ).environment(model),
            appearance: .aqua,
            fileName: "AgentGitSettings-repair.png",
            size: NSSize(width: 560, height: 620)
        )
    }

    private func render(
        _ content: some View,
        appearance: NSAppearance.Name,
        fileName: String,
        size: NSSize = NSSize(width: 560, height: 652)
    ) async throws {
        let colorScheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let hostingView = NSHostingView(
            rootView: content.environment(\.colorScheme, colorScheme)
        )
        let resolvedAppearance = try XCTUnwrap(NSAppearance(named: appearance))
        hostingView.appearance = resolvedAppearance
        hostingView.wantsLayer = true
        var backgroundColor = NSColor.windowBackgroundColor.cgColor
        resolvedAppearance.performAsCurrentDrawingAppearance {
            backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        hostingView.layer?.backgroundColor = backgroundColor
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = resolvedAppearance
        resolvedAppearance.performAsCurrentDrawingAppearance {
            window.backgroundColor = NSColor.windowBackgroundColor
        }
        window.contentView = hostingView
        window.setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(150))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let settingsNavigation = descendants(of: hostingView).compactMap {
            $0 as? NSSegmentedControl
        }.first
        XCTAssertEqual(settingsNavigation?.segmentCount, 2)
        XCTAssertEqual(settingsNavigation?.label(forSegment: 0), "Review")
        XCTAssertEqual(settingsNavigation?.label(forSegment: 1), "Agents")

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        let output = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(".build/verification/\(fileName)")
        try png.write(to: output)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
