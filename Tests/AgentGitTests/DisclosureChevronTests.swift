@testable import AgentGitApp
import AppKit
import Testing

@Test @MainActor func disclosureChevronKeepsItsFrameAcrossTogglesAndReuse() {
    _ = NSApplication.shared
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let frame = NSRect(x: 14, y: 16.5, width: 13, height: 13)
    let chevron = DiffDisclosureView(frame: frame)
    container.addSubview(chevron)
    let center = chevron.convert(NSPoint(x: 6.5, y: 6.5), to: container)

    for expanded in [false, true, false, true, true, false] {
        chevron.setExpanded(expanded)
        chevron.frame = frame
        chevron.layoutSubtreeIfNeeded()
        #expect(chevron.frame == frame)
        #expect(chevron.bounds == NSRect(x: 0, y: 0, width: 13, height: 13))
        #expect(chevron.frameCenterRotation == 0)
        #expect(chevron.layer?.sublayers?.first?.position == NSPoint(x: 6.5, y: 6.5))
        #expect(chevron.convert(NSPoint(x: 6.5, y: 6.5), to: container) == center)
    }
}
