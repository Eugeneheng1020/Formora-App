import Foundation

/// Where a note lives (user 2026-09-17): what holds in every project, what is one project's — every Agent in it reads
/// it — what is one Agent's own in every project, and Bob's own.
enum MemoryScope: Hashable, Codable, Sendable {
    case global
    case project(UUID)
    case agent(UUID)
    case bob

    /// A note's number starts with it: g1, p4, a2, b3.
    var prefix: String {
        switch self {
        case .global: "g"
        case .project: "p"
        case .agent: "a"
        case .bob: "b"
        }
    }

    /// Notes a layer holds: a directory a conversation reads stays about sixty lines (spec §3).
    var cap: Int {
        switch self {
        case .global: 20
        case .project: 30
        case .agent: 10
        case .bob: 20
        }
    }

    /// As the user reads it, in the thread's line and in /memory.
    var label: String {
        switch self {
        case .global: "全局"
        case .project: "项目"
        case .agent: "Agent"
        case .bob: "Bob"
        }
    }

    /// As its reader is told in the directory: its own layer is 「你」.
    var directoryLabel: String {
        switch self {
        case .global: "全局"
        case .project: "项目"
        case .agent, .bob: "你"
        }
    }

    /// What the `remember` tool calls it.
    var name: String {
        switch self {
        case .global: "global"
        case .project: "project"
        case .agent: "agent"
        case .bob: "bob"
        }
    }

    var path: [String] {
        switch self {
        case .global: ["global"]
        case .project(let id): ["projects", id.uuidString]
        case .agent(let id): ["agents", id.uuidString]
        case .bob: ["bob"]
        }
    }
}

/// One note: a sentence that stands in the directory, and — for the few that need it — more to read with `recall`.
struct MemoryEntry: Equatable, Identifiable, Codable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        /// Who the user is.
        case profile
        /// How the user wants things done.
        case preference
        /// What the user settled, with its reason; what was turned down.
        case decision
        /// What failed first and how it was solved — a project's, or Bob's.
        case lesson
    }

    var id: String
    var kind: Kind
    var summary: String
    var body = ""
    /// `yyyy-MM-dd`.
    var created: String
    /// The day it was last read with `recall`, or confirmed by being remembered again.
    var used: String
    /// The conversation it came from.
    var source: UUID?

    var hasBody: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Its number, for the order and for the next one.
    var number: Int { Int(id.drop { !$0.isNumber }) ?? 0 }

    var fileText: String {
        var lines = ["---", "id: \(id)", "kind: \(kind.rawValue)", "summary: \(summary)", "created: \(created)", "used: \(used)"]
        if let source { lines.append("source: \(source.uuidString)") }
        lines.append("---")
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n" + (text.isEmpty ? "" : text + "\n")
    }

    /// A file as `fileText` wrote it — or as the user left it after an edit in Finder; `nil` when it isn't a note.
    static func parse(_ text: String) -> MemoryEntry? {
        var lines = text.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines = lines.dropFirst()
        var fields: [String: String] = [:]
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let id = fields["id"], !id.isEmpty, let summary = fields["summary"], !summary.isEmpty else { return nil }
        let created = fields["created"] ?? MemoryStore.day(.now)
        return MemoryEntry(id: id, kind: fields["kind"].flatMap(Kind.init(rawValue:)) ?? .preference, summary: summary,
                           body: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), created: created,
                           used: fields["used"] ?? created, source: fields["source"].flatMap(UUID.init(uuidString:)))
    }
}

enum MemoryProblem: Error, Equatable {
    case empty
    /// The layer holds its cap already: merge or forget first.
    case full(Int)
    case summaryTooLong(Int)
    case bodyTooLong(Int)
    case unknown(String)
    /// A lesson is a project's, or Bob's.
    case lessonScope

    var message: String {
        switch self {
        case .empty: "没有要记的内容"
        case .full(let cap): "这一层已经有 \(cap) 条，满了。先用 update 把相近的合并，或者用 forget 忘掉过时的，再记新的"
        case .summaryTooLong(let count): "summary 有 \(count) 个字，最多 \(MemoryStore.summaryLimit) 个：一句话说清，细节放进 body"
        case .bodyTooLong(let tokens): "body 约 \(tokens) token，最多 \(MemoryStore.bodyTokenLimit)：只留下次用得上的"
        case .unknown(let id): "没有编号为 \(id) 的记忆"
        case .lessonScope: "踩坑的经验（lesson）只记在项目层"
        }
    }
}
