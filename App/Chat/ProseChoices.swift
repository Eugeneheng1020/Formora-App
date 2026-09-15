import Foundation

/// 文字里的方案也做成卡片 (user 2026-09-15): a reply that lists numbered ways and asks which one — 「三种走法：1. … 2. … 3. …
/// 我推荐 2」 — becomes the same option card as `ask`, the recommended one marked. Conservative: a numbered list alone is
/// a plan, not a choice; the words after it have to ask.
enum ProseChoices {
    struct Choice: Equatable, Sendable {
        let number: Int
        let label: String
        let description: String?
    }

    struct Found: Equatable, Sendable {
        /// The line that introduced the list, or a standing one.
        let prompt: String
        let choices: [Choice]
        /// 0-based, from 「推荐 2」 / 「推荐第二个」.
        let recommended: Int?
    }

    static let limit = 6
    static let labelLimit = 40

    private static let item = try! NSRegularExpression(pattern: #"^\s*(\d{1,2})\s*[.、．)）]\s*(.+)$"#)
    /// The words after the list have to put the choice to the user.
    private static let invitation = try! NSRegularExpression(
        pattern: #"推荐|选哪|哪个|哪种|哪一|你定|你来定|你选|你挑|要哪|按哪|选\s*[0-9一二三四五六]"#)
    private static let recommendation = try! NSRegularExpression(pattern: #"推荐\s*(?:方案|走法|选项|做法|第)?\s*([0-9一二三四五六])"#)
    private static let numerals: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6]

    static func find(in text: String) -> Found? {
        let lines = text.components(separatedBy: .newlines)
        var items: [(number: Int, text: String)] = []
        var intro: String?
        var tail: [String] = []
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)
            index += 1
            if let match = item.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let number = Range(match.range(at: 1), in: line).flatMap({ Int(line[$0]) }),
               let body = Range(match.range(at: 2), in: line).map({ String(line[$0]) }), tail.isEmpty {
                if number == items.count + 1 {
                    items.append((number, body))
                    continue
                }
                if number == 1 {
                    items = [(1, body)]
                    continue
                }
            }
            if line.isEmpty {
                if !tail.isEmpty { tail.append(line) }
                continue
            }
            if tail.isEmpty, !items.isEmpty, raw.first?.isWhitespace == true || line.hasPrefix("-") || line.hasPrefix("·") || line.hasPrefix("•") {
                // A continuation of the item above.
                items[items.count - 1].text += " " + line.drop { "-·• ".contains($0) }
                continue
            }
            if items.count >= 2 {
                tail.append(line)
            } else {
                items = []
                intro = line
            }
        }
        guard (2...limit).contains(items.count) else { return nil }
        let after = tail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !after.isEmpty, invitation.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) != nil else { return nil }
        let choices = items.map { choice($0.number, $0.text) }
        let recommended = recommendation.firstMatch(in: after, range: NSRange(after.startIndex..., in: after))
            .flatMap { Range($0.range(at: 1), in: after) }
            .flatMap { range -> Int? in
                let mark = after[range]
                return Int(mark) ?? mark.first.flatMap { numerals[$0] }
            }
            .flatMap { choices.indices.contains($0 - 1) ? $0 - 1 : nil }
        let prompt = intro.map(Self.plain).map { $0.hasSuffix("：") || $0.hasSuffix(":") ? String($0.dropLast()) : $0 }
        return Found(prompt: prompt?.isEmpty == false ? prompt! : "它给了 \(choices.count) 个方案，选一个", choices: choices, recommended: recommended)
    }

    /// What the pick says, in the user's voice: 「选 2：Dock 三项不动」.
    static func reply(_ choice: Choice) -> String { "选 \(choice.number)：\(choice.label)" }

    /// The item's first sentence is its name, the rest what it means; a long first sentence is cut at its first comma.
    private static func choice(_ number: Int, _ text: String) -> Choice {
        let body = plain(text)
        let stops: Set<Character> = ["。", "！", "？", "；", "：", ":", "!", "?", ";"]
        var label = String(body.prefix { !stops.contains($0) })
        var rest = String(body.dropFirst(label.count))
        if label.count > labelLimit, let comma = label.firstIndex(where: { $0 == "，" || $0 == "," }), label.distance(from: label.startIndex, to: comma) >= 4 {
            rest = String(label[comma...]) + rest
            label = String(label[..<comma])
        }
        if label.count > labelLimit { label = String(label.prefix(labelLimit)) + "…" }
        let description = rest.drop { stops.contains($0) || $0 == "，" || $0 == "," || $0 == " " }.trimmingCharacters(in: .whitespaces)
        return Choice(number: number, label: label.trimmingCharacters(in: .whitespaces), description: description.isEmpty ? nil : description)
    }

    /// Without Markdown's emphasis marks.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").trimmingCharacters(in: .whitespaces)
    }
}
