import AppKit
import XCTest
@testable import AgentGitApp

@MainActor
final class FontScaleTests: XCTestCase {
    func testScaleIsBoundedPersistedAndResettable() throws {
        let suite = "AgentGitFontScaleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = FontScaleSettings(defaults: defaults)
        XCTAssertEqual(settings.percent, 100)
        settings.perform(.increase)
        XCTAssertEqual(settings.percent, 110)
        XCTAssertEqual(FontScaleSettings(defaults: defaults).percent, 110)
        for _ in 0..<10 { settings.perform(.increase) }
        XCTAssertEqual(settings.percent, 150)
        XCTAssertFalse(settings.canIncrease)
        for _ in 0..<10 { settings.perform(.decrease) }
        XCTAssertEqual(settings.percent, 80)
        XCTAssertFalse(settings.canDecrease)
        settings.perform(.reset)
        XCTAssertEqual(FontScaleSettings(defaults: defaults).percent, 100)
    }

    func testShortcutsAcceptBothPlusKeysAndPreserveNormalTyping() {
        XCTAssertEqual(FontScaleSettings.action(for: "=", modifiers: .command), .increase)
        XCTAssertEqual(FontScaleSettings.action(for: "+", modifiers: [.command, .shift]), .increase)
        XCTAssertEqual(FontScaleSettings.action(for: "-", modifiers: .command), .decrease)
        XCTAssertEqual(FontScaleSettings.action(for: "0", modifiers: .command), .reset)
        XCTAssertNil(FontScaleSettings.action(for: "+", modifiers: .shift))
        XCTAssertNil(FontScaleSettings.action(for: "-", modifiers: []))
        XCTAssertNil(FontScaleSettings.action(for: "=", modifiers: [.command, .option]))
        XCTAssertNil(FontScaleSettings.action(for: "+", modifiers: [.command, .control]))
    }
}
