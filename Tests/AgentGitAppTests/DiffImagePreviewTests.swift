import AppKit
import XCTest
@testable import AgentGitApp

@MainActor
final class DiffImagePreviewTests: XCTestCase {
    func testDecoderDownsamplesLargeImageAndPreservesOriginalDimensions() throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1_024,
                pixelsHigh: 512,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let data = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )

        let preview = try XCTUnwrap(
            DiffImagePreviewDecoder.decode(data, maximumPixelSize: 256)
        )

        XCTAssertEqual(preview.originalPixelWidth, 1_024)
        XCTAssertEqual(preview.originalPixelHeight, 512)
        XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 256)
        XCTAssertLessThanOrEqual(preview.memoryCost, 256 * 256 * 4)
    }

    func testDecoderRejectsInvalidImageData() {
        XCTAssertNil(
            DiffImagePreviewDecoder.decode(Data("invalid image".utf8))
        )
    }
}
