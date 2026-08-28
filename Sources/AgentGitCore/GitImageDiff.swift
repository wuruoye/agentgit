import Foundation
import UniformTypeIdentifiers

public struct GitImageBlob: Hashable, Sendable {
    public let path: String
    public let contents: Data
    public let contentHash: Int

    public init(path: String, contents: Data) {
        self.path = path
        self.contents = contents
        contentHash = contents.hashValue
    }

    public static func == (lhs: GitImageBlob, rhs: GitImageBlob) -> Bool {
        lhs.path == rhs.path && lhs.contents == rhs.contents
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(contents.count)
        hasher.combine(contentHash)
    }
}

public struct GitImageDiff: Hashable, Sendable {
    public static let maximumBlobByteCount = 32 * 1_024 * 1_024

    public let oldImage: GitImageBlob?
    public let newImage: GitImageBlob?

    public init(oldImage: GitImageBlob?, newImage: GitImageBlob?) {
        self.oldImage = oldImage
        self.newImage = newImage
    }

    public static func supports(path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }
}

public enum GitImageDiffError: LocalizedError, Equatable, Sendable {
    case tooLarge(path: String, byteCount: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(path, byteCount, limit):
            "\(path) contains \(byteCount) bytes; image preview limit is \(limit) bytes."
        }
    }
}
