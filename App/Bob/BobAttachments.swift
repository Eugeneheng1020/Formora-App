import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A file the user hands Bob (D96, user 2026-09-13): kept in Formora's own folder, not the project's 附件/ — like his
/// memory, it isn't tied to a project, and it doesn't fill the project with what was only meant for him.
struct BobAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case image, video, text, file
    }

    let id: UUID
    let name: String
    let url: URL
    let kind: Kind
    /// A video's frames, cut when it was attached.
    var frames: [ChatImage] = []
    /// A video's length in seconds.
    var duration: Double?
}

enum BobAttachments {
    static let folderName = "BobAttachments"
    /// A text file's words go in the message up to this many characters; past it, where to read the rest.
    static let textLimit = 20_000

    /// Copied into `folder` under a name not taken yet (`名字 2.md` …).
    static func store(_ url: URL, in folder: URL) throws -> BobAttachment {
        let target = try unique(url.lastPathComponent, in: folder)
        try FileManager.default.copyItem(at: url, to: target)
        return BobAttachment(id: UUID(), name: target.lastPathComponent, url: target, kind: kind(of: target))
    }

    /// A pasted picture becomes a PNG.
    static func storePasted(_ png: Data, in folder: URL, now: Date = .now) throws -> BobAttachment {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let target = try unique("粘贴图片 \(formatter.string(from: now)).png", in: folder)
        try png.write(to: target, options: .atomic)
        return BobAttachment(id: UUID(), name: target.lastPathComponent, url: target, kind: .image)
    }

    static func kind(of url: URL) -> BobAttachment.Kind {
        if ChatImages.isImage(url) { return .image }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .xml) { return .text }
        return .file
    }

    /// The user's turn as the model reads it: the words, then each file — a text file's words, a picture or a video's
    /// frames for a model that sees them, a line saying what it is otherwise.
    static func turn(_ text: String, _ attachments: [BobAttachment], seesImages: Bool) -> ChatTurn {
        var parts = text.isEmpty ? [] : [text]
        var images: [ChatImage] = []
        var unseen = 0
        for item in attachments {
            switch item.kind {
            case .text:
                let body = (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
                let shown = body.count > textLimit ? String(body.prefix(textLimit)) + "\n…（后面还有，用 read 读 \(item.url.path)）" : body
                parts.append("附件「\(item.name)」（\(item.url.path)）：\n\(shown)")
            case .image:
                if seesImages, let picture = ChatImages.load(item.url) {
                    images.append(picture)
                    parts.append("附件「\(item.name)」：一张图片，随消息附上。")
                } else {
                    unseen += 1
                    parts.append("附件「\(item.name)」（\(item.url.path)）：一张图片。")
                }
            case .video:
                let length = item.duration.map(clock) ?? "不明"
                if seesImages, !item.frames.isEmpty {
                    images += item.frames
                    parts.append("附件「\(item.name)」：视频，时长 \(length)。随消息附上从头到尾均匀截的 \(item.frames.count) 张画面，按时间先后；听不到声音，画面之间发生的看不到。")
                } else {
                    parts.append("附件「\(item.name)」（\(item.url.path)）：视频，时长 \(length)。"
                                 + (seesImages ? "没能截出画面。" : "当前模型看不了图，看不到画面。"))
                }
            case .file:
                parts.append("附件「\(item.name)」在 \(item.url.path)：不是文本文件；PDF、Word、Excel、PPT 用对应的 Skill 读。")
            }
        }
        if unseen > 0 { parts.append(ChatImages.unseen(unseen)) }
        return ChatTurn(role: .user, text: parts.joined(separator: "\n\n"), images: images)
    }

    /// 75 → 「1:15」.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func unique(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

/// Most models can't watch a video (D96): a few frames spread over it, for a model that sees pictures.
enum BobVideo {
    static let frameCount = 8

    /// Its length and up to `count` frames, never more than two a second; `nil` when it can't be read as a video.
    static func sample(_ url: URL, count: Int = frameCount) async -> (duration: Double, frames: [ChatImage])? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let length = try? await asset.load(.duration), length.seconds.isFinite, length.seconds > 0 else { return nil }
        let seconds = length.seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: ChatImages.longEdge, height: ChatImages.longEdge)
        let tolerance = CMTime(seconds: min(0.5, seconds / Double(count * 2)), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let wanted = max(1, min(count, Int(seconds * 2)))
        var frames: [ChatImage] = []
        for index in 0..<wanted {
            let time = CMTime(seconds: seconds * (Double(index) + 0.5) / Double(wanted), preferredTimescale: 600)
            if let frame = try? await generator.image(at: time), let encoded = ChatImages.encode(frame.image) {
                frames.append(encoded)
            }
        }
        return (seconds, frames)
    }
}
