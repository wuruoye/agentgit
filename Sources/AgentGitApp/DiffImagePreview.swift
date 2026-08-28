import AgentGitCore
import AppKit
import ImageIO

struct DiffImagePreview: @unchecked Sendable {
    let image: CGImage
    let originalPixelWidth: Int
    let originalPixelHeight: Int

    var memoryCost: Int {
        image.bytesPerRow * image.height
    }
}

enum DiffImagePreviewDecoder {
    static let maximumPixelSize = 2_048

    nonisolated static func decode(
        _ data: Data,
        maximumPixelSize: Int = maximumPixelSize
    ) -> DiffImagePreview? {
        guard !Task.isCancelled, maximumPixelSize > 0,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let originalPixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?
            .intValue
        let originalPixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?
            .intValue
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), !Task.isCancelled else {
            return nil
        }
        return DiffImagePreview(
            image: image,
            originalPixelWidth: originalPixelWidth ?? image.width,
            originalPixelHeight: originalPixelHeight ?? image.height
        )
    }
}

struct DiffImagePreviewID: Hashable, Sendable {
    let path: String
    let byteCount: Int
    let contentHash: Int

    init(_ blob: GitImageBlob) {
        path = blob.path
        byteCount = blob.contents.count
        contentHash = blob.contentHash
    }

    var cacheKey: NSString {
        "\(contentHash):\(byteCount):\(path)" as NSString
    }
}

@MainActor
final class DiffImagePreviewCache {
    static let shared = DiffImagePreviewCache()

    private final class Entry {
        let preview: DiffImagePreview

        init(_ preview: DiffImagePreview) {
            self.preview = preview
        }
    }

    private let values = NSCache<NSString, Entry>()

    private init() {
        values.countLimit = 16
        values.totalCostLimit = 128 * 1_024 * 1_024
    }

    func preview(for id: DiffImagePreviewID) -> DiffImagePreview? {
        values.object(forKey: id.cacheKey)?.preview
    }

    func insert(_ preview: DiffImagePreview, for id: DiffImagePreviewID) {
        values.setObject(
            Entry(preview),
            forKey: id.cacheKey,
            cost: preview.memoryCost
        )
    }
}
