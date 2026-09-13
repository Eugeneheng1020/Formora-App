import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image sent with a turn (7j, V1): its bytes, already fitted for the model.
struct ChatImage: Equatable, Sendable {
    var mediaType: String
    var base64: String

    var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}

/// Images for the model (7j, V1–V2): read from disk when a request is made, the long edge fitted to 1568 — what
/// Anthropic recommends and the others accept. JPEG, or PNG when the picture has transparency.
enum ChatImages {
    static let longEdge = 1568
    static let fileLimit = 20 * 1024 * 1024
    /// What the model reads in place of pictures it can't see (V2).
    static func unseen(_ count: Int) -> String {
        count == 1 ? "（这里有一张图片，当前模型看不了图）" : "（这里有 \(count) 张图片，当前模型看不了图）"
    }

    /// A picture file by its extension; SVG is text and is read as text.
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// The picture's size in pixels, `nil` when the file isn't one.
    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let rotated = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return rotated ? (height, width) : (width, height)
    }

    /// The file as the model receives it; `nil` when it can't be read as a picture or is too large.
    static func load(_ url: URL) -> ChatImage? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        guard size > 0, size <= fileLimit else { return nil }
        let key = "\(url.path)|\(size)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = cache.value(key) { return cached }
        guard let image = encode(url) else { return nil }
        cache.store(image, for: key)
        return image
    }

    private static func encode(_ url: URL) -> ChatImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let (width, height) = pixelSize(url) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasAlpha = properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
        // Always through the thumbnail path: it applies the EXIF orientation and turns HEIC, TIFF and the rest
        // into a format every provider takes.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, max(width, height)),
        ]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ChatImage(mediaType: type.preferredMIMEType ?? (hasAlpha ? "image/png" : "image/jpeg"),
                         base64: (data as Data).base64EncodedString())
    }

    /// Every model call rebuilds the history; a run full of screenshots shouldn't re-encode them each time.
    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: ChatImage] = [:]

        func value(_ key: String) -> ChatImage? {
            lock.lock()
            defer { lock.unlock() }
            return images[key]
        }

        func store(_ image: ChatImage, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if images.count >= 64 { images.removeAll() }
            images[key] = image
        }
    }
}
