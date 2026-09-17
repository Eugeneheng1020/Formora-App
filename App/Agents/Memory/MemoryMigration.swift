import Foundation

/// The first start over the old layout (`<Agent>/<项目>.md`, four sections of dated lines; user 2026-09-17). Bob's
/// notes move into his layer as they were dated — his memory was never a project's. The Agents' old files are put
/// away in `_legacy/`, not carried over: they were written under the loose rules this replaces, and none of their
/// lines could show the evidence a note now needs. Nothing is deleted. A failure leaves the start alone.
enum MemoryMigration {
    @MainActor
    static func run(folder: URL, store: MemoryStore, bobID: UUID = Conductor.bobID, everywhere: UUID = BobSession.everywhere) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return }
        let old = names.filter { UUID(uuidString: $0) != nil }
        guard !old.isEmpty else { return }
        let legacy = folder.appendingPathComponent(MemoryStore.legacyFolder, isDirectory: true)
        try? files.createDirectory(at: legacy, withIntermediateDirectories: true)
        for name in old {
            let source = folder.appendingPathComponent(name, isDirectory: true)
            if UUID(uuidString: name) == bobID,
               let text = try? String(contentsOf: source.appendingPathComponent("\(everywhere.uuidString).md"), encoding: .utf8) {
                for note in notes(in: text) {
                    // A line longer than a summary may be: its beginning stands in the directory, all of it is the body.
                    let fits = note.text.count <= MemoryStore.summaryLimit
                    _ = store.add(kind: note.kind, summary: fits ? note.text : String(note.text.prefix(MemoryStore.summaryLimit - 1)) + "…",
                                  body: fits ? "" : note.text, to: .bob, source: nil, now: note.date ?? .now)
                }
            }
            let target = legacy.appendingPathComponent(name, isDirectory: true)
            guard !files.fileExists(atPath: target.path) else { continue }
            try? files.moveItem(at: source, to: target)
        }
    }

    /// The old file's lines: 「- 内容（YYYY-MM-DD）」 under 用户偏好 / 项目约定 / 已定的结论 / 要记住的事.
    static func notes(in text: String) -> [(kind: MemoryEntry.Kind, text: String, date: Date?)] {
        var kind = MemoryEntry.Kind.lesson
        var found: [(MemoryEntry.Kind, String, Date?)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                switch line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) {
                case "用户偏好": kind = .preference
                case "项目约定", "已定的结论": kind = .decision
                default: kind = .lesson
                }
                continue
            }
            if line.hasPrefix("- ") { line.removeFirst(2) }
            var date: Date?
            if let range = line.range(of: #"（\d{4}-\d{2}-\d{2}）\s*$"#, options: .regularExpression) {
                date = MemoryStore.date(String(line[range].filter { $0.isNumber || $0 == "-" }))
                line.removeSubrange(range)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { found.append((kind, line, date)) }
        }
        return found
    }
}
