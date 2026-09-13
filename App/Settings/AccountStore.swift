import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Avatar import rules (design spec §7.1): PNG, JPEG or HEIC, at most 10 MB, centre-cropped to a square.
enum AvatarImage {
    static let maxBytes = 10 * 1024 * 1024
    /// Stored size in pixels: twice the 56pt preview, with room to spare.
    static let side = 256
    static let allowedTypes: [UTType] = [.png, .jpeg, .heic]

    enum Problem: Error, Equatable {
        case unsupportedFormat, tooLarge, unreadable

        var message: String {
            switch self {
            case .unsupportedFormat: "只支持 PNG、JPEG、HEIC 图片"
            case .tooLarge: "图片不能超过 10 MB"
            case .unreadable: "这张图片无法读取"
            }
        }
    }

    /// Reads, checks, crops the centre square (respecting EXIF orientation) and scales it to `side`; returns PNG data.
    static func prepare(from url: URL) throws -> Data {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              allowedTypes.contains(where: { type.conforms(to: $0) }) else { throw Problem.unsupportedFormat }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes <= maxBytes else { throw Problem.tooLarge }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw Problem.unreadable }

        let short = min(image.width, image.height)
        let crop = CGRect(x: (image.width - short) / 2, y: (image.height - short) / 2, width: short, height: short)
        guard let square = image.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Problem.unreadable
        }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Problem.unreadable
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw Problem.unreadable }
        return data as Data
    }
}

/// 设置 → 账户: the nickname and avatar shown on the rail. Local display only — it takes part in no Agent
/// configuration (mockup note for the category).
@MainActor
@Observable
final class AccountStore {
    static let nicknameKey = "formora.account.nickname"
    /// Counted in Unicode code points, like every length limit in the product (design changelog #24).
    nonisolated static let maxNicknameLength = 20
    static let avatarFileName = "avatar.png"

    /// The macOS full name: what the rail shows while no nickname is set (design spec §3).
    let systemName: String
    private(set) var nickname: String
    private(set) var avatar: NSImage?

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let folder: URL?

    /// `defaults` / `folder` `nil` keep everything in memory (tests, previews).
    init(defaults: UserDefaults?, folder: URL?, systemName: String = NSFullUserName()) {
        self.defaults = defaults
        self.folder = folder
        self.systemName = systemName
        nickname = defaults?.string(forKey: Self.nicknameKey) ?? ""
        avatar = folder.flatMap { NSImage(contentsOf: $0.appendingPathComponent(Self.avatarFileName)) }
    }

    var displayName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? systemName : trimmed
    }

    var initial: String? { AccountIdentity.initial(of: displayName) }

    /// Saved as typed (clamped), so the field never jumps while editing.
    func setNickname(_ raw: String) {
        let clamped = Self.clamp(raw)
        nickname = clamped
        defaults?.set(clamped, forKey: Self.nicknameKey)
    }

    nonisolated static func clamp(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.unicodeScalars.prefix(maxNicknameLength)))
    }

    func importAvatar(from url: URL) throws {
        let data = try AvatarImage.prepare(from: url)
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(Self.avatarFileName), options: .atomic)
        }
        avatar = NSImage(data: data)
    }

    func removeAvatar() {
        if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.avatarFileName)) }
        avatar = nil
    }
}
