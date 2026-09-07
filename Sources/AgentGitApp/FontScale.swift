import AppKit
import Observation
import SwiftUI

enum FontScaleAction { case increase, decrease, reset }

@MainActor
@Observable
final class FontScaleSettings {
    static let shared = FontScaleSettings()
    private static let defaultsKey = "agentgit.font-scale-step"
    private let defaults: UserDefaults
    private var shortcutMonitor: Any?
    private(set) var step: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        step = min(5, max(-2, defaults.integer(forKey: Self.defaultsKey)))
    }

    var scale: CGFloat { CGFloat(100 + step * 10) / 100 }
    var percent: Int { 100 + step * 10 }
    var canIncrease: Bool { step < 5 }
    var canDecrease: Bool { step > -2 }

    func perform(_ action: FontScaleAction) {
        let next: Int
        switch action {
        case .increase: next = min(5, step + 1)
        case .decrease: next = max(-2, step - 1)
        case .reset: next = 0
        }
        guard next != step else { return }
        step = next
        defaults.set(step, forKey: Self.defaultsKey)
    }

    static func action(for characters: String, modifiers: NSEvent.ModifierFlags) -> FontScaleAction? {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        guard relevant.contains(.command), !relevant.contains(.option), !relevant.contains(.control) else { return nil }
        switch characters {
        case "+", "=": return .increase
        case "-" where !relevant.contains(.shift): return .decrease
        case "0" where !relevant.contains(.shift): return .reset
        default: return nil
        }
    }

    func installKeyboardShortcuts() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let characters = event.charactersIgnoringModifiers,
                  let action = Self.action(for: characters, modifiers: event.modifierFlags) else { return event }
            self?.perform(action)
            return nil
        }
    }
}

private struct FontScaleSettingsKey: EnvironmentKey {
    static let defaultValue: FontScaleSettings? = nil
}

extension EnvironmentValues {
    var fontScaleSettings: FontScaleSettings? {
        get { self[FontScaleSettingsKey.self] }
        set { self[FontScaleSettingsKey.self] = newValue }
    }
}

/// Keep text, native Diff rows and their hit areas in the same coordinate system.
/// Zoom changes presentation; the existing review state and loaded Git data stay alive.
struct FontScaleViewport<Content: View>: View {
    @Environment(\.fontScaleSettings) private var suppliedSettings
    private let explicitSettings: FontScaleSettings?
    let content: Content

    init(settings: FontScaleSettings? = nil, @ViewBuilder content: () -> Content) {
        explicitSettings = settings
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = (explicitSettings ?? suppliedSettings ?? .shared).scale
            content
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .clipped()
    }
}

private struct FixedFontScaleModifier: ViewModifier {
    private let settings = FontScaleSettings.shared
    let width: CGFloat
    let height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    func body(content: Content) -> some View {
        let screen = NSApp.keyWindow?.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size
        let availableWidth = max(640, (screen?.width ?? 2_000) - 80)
        let availableHeight = max(360, (screen?.height ?? 1_200) - 100)
        FontScaleViewport {
            content
        }
        .frame(width: min(width * settings.scale, availableWidth), height: min(height * settings.scale, availableHeight))
    }
}

extension View {
    func scaledFontPresentation(width: CGFloat, height: CGFloat) -> some View {
        modifier(FixedFontScaleModifier(width: width, height: height))
    }
}

struct FontScaleCommands: Commands {
    private let settings = FontScaleSettings.shared

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Text("Font Size: \(settings.percent)%")
            Button("Increase Font Size") { settings.perform(.increase) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!settings.canIncrease)
            Button("Decrease Font Size") { settings.perform(.decrease) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!settings.canDecrease)
            Button("Actual Font Size") { settings.perform(.reset) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
