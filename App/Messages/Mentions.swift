import Foundation

/// `@` in group chats (spec §9.10): who a message is for.
enum Mentions {
    /// The members `@`-ed in `text`, in the order they first appear. A member answers to its full name
    /// 「研发（前端）」 and to its own name 「前端」; longer names are tried first so one can't claim part of another.
    @MainActor
    static func assignees(in text: String, members: [AgentRecord]) -> [UUID] {
        assignees(in: text, names: members.flatMap { [($0.displayName, $0.id), ($0.customName, $0.id)] })
    }

    static func assignees(in text: String, names: [(String, UUID)]) -> [UUID] {
        var claimed: [Range<String.Index>] = []
        var found: [(at: String.Index, id: UUID)] = []
        for (name, id) in names.filter({ !$0.0.isEmpty }).sorted(by: { $0.0.count > $1.0.count }) {
            for range in ranges(of: "@" + name, in: text) where !claimed.contains(where: { $0.overlaps(range) }) {
                claimed.append(range)
                found.append((range.lowerBound, id))
            }
        }
        var seen = Set<UUID>()
        return found.sorted { $0.at < $1.at }.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    }

    /// Every occurrence, case and width folded like the rest of the app's matching.
    static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let range = text.range(of: needle, options: [.caseInsensitive, .widthInsensitive], range: from..<text.endIndex) {
            result.append(range)
            from = range.upperBound
        }
        return result
    }
}
