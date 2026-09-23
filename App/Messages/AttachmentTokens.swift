import Foundation

/// 图片和文件塞进消息文字里 (user 2026-09-23: 「参照 [image1] [file name] 这样，并颜色标记」): a pasted picture or an added file
/// is written into the words as a tag where the caret was — `[image1]`, `[image2]`, or `[文件名]` — in the accent colour.
/// Deleting the tag leaves the attachment out; the model reads which file each tag is.
enum AttachmentTokens {
    /// A label for the next attachment of this draft: pictures are numbered, files go by name (a second file of the same
    /// name gets ` 2`).
    static func label(for attachment: Attachment, among existing: [Attachment]) -> String {
        let taken = Set(existing.compactMap(\.label))
        if attachment.kind == .image {
            let used = existing.compactMap(\.label).compactMap { label -> Int? in
                guard label.hasPrefix("image") else { return nil }
                return Int(label.dropFirst(5))
            }
            var number = (used.max() ?? 0) + 1
            while taken.contains("image\(number)") { number += 1 }
            return "image\(number)"
        }
        var label = attachment.name
        var number = 2
        while taken.contains(label) {
            label = "\(attachment.name) \(number)"
            number += 1
        }
        return label
    }

    /// What goes with the message: the attachments whose tag is still in the words (and any from before, untagged).
    static func kept(_ attachments: [Attachment], in text: String) -> [Attachment] {
        attachments.filter { attachment in attachment.token.map(text.contains) ?? true }
    }

    /// Where each tag sits in the words, for colouring.
    static func ranges(in text: String, attachments: [Attachment]) -> [(Range<String.Index>, Attachment)] {
        attachments.flatMap { attachment -> [(Range<String.Index>, Attachment)] in
            guard let token = attachment.token else { return [] }
            var found: [(Range<String.Index>, Attachment)] = []
            var from = text.startIndex
            while let range = text.range(of: token, range: from..<text.endIndex) {
                found.append((range, attachment))
                from = range.upperBound
            }
            return found
        }
    }

    /// The line the model reads under the user's words: which file each tag is. Untagged ones (older messages) keep the
    /// old line, so a saved conversation's history — and its cached prefix — doesn't change.
    static func modelLine(_ attachments: [Attachment]) -> String {
        "附件：" + attachments.map { attachment in
            attachment.token.map { "\($0) = \(attachment.relativePath)" } ?? attachment.relativePath
        }.joined(separator: "、")
    }
}
