import AgentGitCore
import AppKit
import SwiftUI
import XCTest
@testable import AgentGitApp

@MainActor
final class AppModelTests: XCTestCase {
    func testDiffSettingsPersistAcrossModelInstances() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults)
        model.diffLayout = .sideBySide
        model.diffOptions = GitDiffOptions(
            context: .lines(25),
            ignoresWhitespace: true
        )

        let restored = AppModel(defaults: defaults)
        XCTAssertEqual(restored.diffLayout, .sideBySide)
        XCTAssertEqual(restored.diffOptions.context, .lines(25))
        XCTAssertTrue(restored.diffOptions.ignoresWhitespace)
    }

    func testUnknownStoredDiffSettingsUseDefaults() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown", forKey: "agentgit.diff-context")
        defaults.set("unknown", forKey: "agentgit.diff-layout")

        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.diffLayout, .unified)
        XCTAssertEqual(model.diffOptions.context, .lines(3))
    }

    func testRendersSettingsPageOffscreen() throws {
        let suiteName = "AgentGitAppTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        let hostingView = NSHostingView(
            rootView: AgentGitSettingsView().environment(model)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 460, height: 230)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentGitSettings.png")
        try png.write(to: output)
        print("AgentGit settings snapshot: \(output.path)")
    }
}
