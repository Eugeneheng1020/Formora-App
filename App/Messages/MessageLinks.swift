import Foundation
import SwiftUI

/// 消息里的文件带超链接 (user 2026-09-15): in a reply's words, a web address opens in the browser and a project path that
/// really exists opens in 文件. Pure over the text; the view supplies `exists`.
enum MessageLinks {
    private static let web = try! NSRegularExpression(pattern: #"https?://[^\s<>()（）「」『』"'，。、；：！？]+"#)
    /// A relative path with an extension: `PRD/会员等级体系_v1.md`, `README.md`, `src/main.swift`. Not a number like 1.0.4.
    private static let path = try! NSRegularExpression(
        pattern: #"(?<![\w/.\-])(?:[\p{L}\p{N}_\-]+/)*[\p{L}\p{N}_\-]*\p{L}[\p{L}\p{N}_\-]*\.[A-Za-z][A-Za-z0-9]{0,7}(?![\w/.\-])"#)

    static func linkify(_ text: AttributedString, exists: (String) -> Bool) -> AttributedString {
        var out = text
        let plain = String(text.characters)
        let whole = NSRange(plain.startIndex..., in: plain)
        var taken: [Range<String.Index>] = []
        for match in web.matches(in: plain, range: whole) {
            guard let range = Range(match.range, in: plain), let url = URL(string: String(plain[range])) else { continue }
            if apply(url, range, in: &out, plain: plain) { taken.append(range) }
        }
        for match in path.matches(in: plain, range: whole) {
            guard let range = Range(match.range, in: plain), !taken.contains(where: { $0.overlaps(range) }) else { continue }
            let candidate = String(plain[range])
            guard exists(candidate), let url = FileMentions.link(candidate) else { continue }
            _ = apply(url, range, in: &out, plain: plain)
        }
        return out
    }

    /// Links the range unless part of it is a link already; `false` when it was.
    private static func apply(_ url: URL, _ range: Range<String.Index>, in text: inout AttributedString, plain: String) -> Bool {
        guard let lower = AttributedString.Index(range.lowerBound, within: text),
              let upper = AttributedString.Index(range.upperBound, within: text) else { return false }
        guard text[lower..<upper].runs.allSatisfy({ $0.link == nil }) else { return false }
        text[lower..<upper].link = url
        text[lower..<upper].foregroundColor = Palette.accent.color
        text[lower..<upper].underlineStyle = .single
        return true
    }
}
