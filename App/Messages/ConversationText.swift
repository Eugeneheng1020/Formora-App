import Foundation

/// The small text rules of 消息: task-name fallback, row time labels, search snippets.
enum ConversationText {
    static let titleLength = 20

    /// Until the model names tasks (phase 7): the first sentence, cut at 20 code points (spec §9.4 — an
    /// honest fallback rather than a made-up title). `nil` when there is no text.
    static func fallbackTitle(from text: String) -> String? {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A group message usually opens with whom it's for; the task is what follows.
        while trimmed.hasPrefix("@") {
            trimmed = String(trimmed.drop { !$0.isWhitespace }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sentence = String(trimmed.prefix { !enders.contains($0) }).trimmingCharacters(in: .whitespaces)
        let cut = String(String.UnicodeScalarView(sentence.unicodeScalars.prefix(titleLength)))
        // A cut that lands on a comma would leave 「……的需求，」 as the name.
        let dangling = CharacterSet(charactersIn: "，、,：:—-…·").union(.whitespaces)
        let title = cut.trimmingCharacters(in: dangling)
        return title.isEmpty ? nil : title
    }

    /// Today → 14:22, yesterday → 昨天, this year → 8月29日, older → 2025/8/29 (the mockup's row times).
    static func timeLabel(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天"
        }
        if calendar.component(.year, from: now) == parts.year {
            return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        }
        return "\(parts.year ?? 0)/\(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    /// Clock time under a bubble.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The matching part of a message for a search row: one line, the match kept in view.
    /// A few characters before the match (a row shows about twenty), the rest after it.
    static func snippet(of text: String, matching query: String, before: Int = 6, after: Int = 40) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let line = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = line.range(of: needle, options: foldingOptions) else { return nil }
        let start = line.distance(from: line.startIndex, to: range.lowerBound)
        let length = line.distance(from: range.lowerBound, to: range.upperBound)
        let characters = Array(line)
        let from = max(0, start - before)
        let to = min(characters.count, start + length + after)
        let body = String(characters[from..<to]).trimmingCharacters(in: .whitespaces)
        return (from > 0 ? "…" : "") + body + (to < characters.count ? "…" : "")
    }

    /// Case and full / half width folded, like the file tree's search.
    static let foldingOptions: String.CompareOptions = [.caseInsensitive, .widthInsensitive]

    static func matches(_ text: String, _ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !needle.isEmpty && text.range(of: needle, options: foldingOptions) != nil
    }
}
