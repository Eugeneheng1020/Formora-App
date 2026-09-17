import Foundation

/// The memory in layers (user 2026-09-17; before: one Markdown file per Agent and project, all of it in every prompt):
/// what holds everywhere, a project's, an Agent's own, Bob's own — one small file a note in the profile's `memory/`
/// (not in the project, not in the file tree: spec §8.3). The prompt carries only the directory — a line a note — and
/// `recall` reads the rest (as Skills load: names first, the body when needed). A note is written one at a time, never
/// the whole memory over again. Read once per layer, then cached.
@MainActor
final class MemoryStore {
    /// 10j: a note not read or confirmed for this long leaves the directory (Codex `max_unused_days`).
    nonisolated static let staleDays = 180
    nonisolated static let summaryLimit = 120
    nonisolated static let bodyTokenLimit = 1_500
    /// Where the files of the old layout are put away.
    nonisolated static let legacyFolder = "_legacy"
    /// A layer's next number, kept beside its notes: a number forgotten is never given again — the thread's line
    /// that can bring the note back still names it.
    private static let counterFile = ".next"

    private let folder: URL?
    private var cache: [MemoryScope: [MemoryEntry]] = [:]
    private var counters: [MemoryScope: Int] = [:]

    init(folder: URL?) {
        self.folder = folder
        if let folder { MemoryMigration.run(folder: folder, store: self) }
    }

    // MARK: Reading

    /// A layer's notes, by number.
    func entries(_ scope: MemoryScope) -> [MemoryEntry] {
        if let cached = cache[scope] { return cached }
        var loaded: [MemoryEntry] = []
        if let folder = url(scope), let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names where name.hasSuffix(".md") {
                guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8),
                      let entry = MemoryEntry.parse(text) else { continue }
                loaded.append(entry)
            }
        }
        loaded.sort { $0.number < $1.number }
        cache[scope] = loaded
        return loaded
    }

    /// What its readers are told of: written, read or confirmed within `staleDays`.
    func fresh(_ scope: MemoryScope, now: Date = .now) -> [MemoryEntry] {
        entries(scope).filter { !Self.isStale($0, now: now) }
    }

    /// Kept on file, shown apart in /memory, not in the directory.
    func stale(_ scope: MemoryScope, now: Date = .now) -> [MemoryEntry] {
        entries(scope).filter { Self.isStale($0, now: now) }
    }

    /// A note by its number — only in the layers the asker may read.
    func find(_ id: String, in scopes: [MemoryScope]) -> (scope: MemoryScope, entry: MemoryEntry)? {
        let wanted = Self.normalized(id)
        for scope in scopes {
            if let entry = entries(scope).first(where: { $0.id == wanted }) { return (scope, entry) }
        }
        return nil
    }

    /// What the prompt carries: a line a note — 「[项目] p4 …（有正文）」 — or `nil` when there is nothing to list.
    func directory(_ scopes: [MemoryScope], now: Date = .now) -> String? {
        let lines = scopes.flatMap { scope in
            fresh(scope, now: now).map { "[\(scope.directoryLabel)] \($0.id) \($0.summary)" + ($0.hasBody ? "（有正文）" : "") }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Writing, a note at a time

    /// A new note under the layer's next number. The same sentence again confirms the one there is (10j): its day
    /// becomes today's and nothing is added.
    func add(kind: MemoryEntry.Kind, summary: String, body: String, to scope: MemoryScope, source: UUID?,
             now: Date = .now) -> Result<(entry: MemoryEntry, confirmed: Bool), MemoryProblem> {
        let line = Self.line(summary)
        guard !line.isEmpty else { return .failure(.empty) }
        if kind == .lesson {
            switch scope {
            case .global, .agent: return .failure(.lessonScope)
            case .project, .bob: break
            }
        }
        if var known = entries(scope).first(where: { $0.summary == line }) {
            known.used = Self.day(now)
            save(known, in: scope)
            return .success((known, true))
        }
        if let problem = Self.problem(summary: line, body: body) { return .failure(problem) }
        guard entries(scope).count < scope.cap else { return .failure(.full(scope.cap)) }
        let today = Self.day(now)
        let entry = MemoryEntry(id: scope.prefix + String(nextNumber(scope)), kind: kind, summary: line, body: Self.text(body),
                                created: today, used: today, source: source)
        save(entry, in: scope)
        return .success((entry, false))
    }

    /// One note changed — what isn't given stays as it was. Changing it confirms it.
    func update(_ id: String, in scope: MemoryScope, summary: String?, body: String?,
                now: Date = .now) -> Result<(before: MemoryEntry, after: MemoryEntry), MemoryProblem> {
        guard let before = entries(scope).first(where: { $0.id == Self.normalized(id) }) else { return .failure(.unknown(id)) }
        var after = before
        if let summary {
            let line = Self.line(summary)
            guard !line.isEmpty else { return .failure(.empty) }
            after.summary = line
        }
        if let body { after.body = Self.text(body) }
        if let problem = Self.problem(summary: after.summary, body: after.body) { return .failure(problem) }
        after.used = Self.day(now)
        save(after, in: scope)
        return .success((before, after))
    }

    func forget(_ id: String, in scope: MemoryScope) -> Result<MemoryEntry, MemoryProblem> {
        guard let entry = entries(scope).first(where: { $0.id == Self.normalized(id) }) else { return .failure(.unknown(id)) }
        cache[scope] = entries(scope).filter { $0.id != entry.id }
        if let url = url(entry.id, in: scope) { try? FileManager.default.removeItem(at: url) }
        return .success(entry)
    }

    /// 撤销: the note as it was, under its own number.
    func restore(_ entry: MemoryEntry, in scope: MemoryScope) {
        save(entry, in: scope)
    }

    /// Read with `recall`: still in use.
    func touch(_ ids: [String], in scope: MemoryScope, now: Date = .now) {
        let today = Self.day(now)
        for var entry in entries(scope) where ids.contains(entry.id) && entry.used != today {
            entry.used = today
            save(entry, in: scope)
        }
    }

    /// A layer emptied — Bob's `memory_clear`.
    func clear(_ scope: MemoryScope) {
        for entry in entries(scope) { _ = forget(entry.id, in: scope) }
    }

    /// The Agent is deleted: its own layer goes with it. What it wrote into a project's stays — the others read it.
    func forget(agent: UUID) {
        let scope = MemoryScope.agent(agent)
        cache[scope] = []
        counters[scope] = nil
        if let url = url(scope) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: The files

    private func save(_ entry: MemoryEntry, in scope: MemoryScope) {
        var all = entries(scope).filter { $0.id != entry.id }
        all.append(entry)
        all.sort { $0.number < $1.number }
        cache[scope] = all
        counters[scope] = max(counters[scope] ?? 0, entry.number + 1)
        guard let url = url(entry.id, in: scope) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(entry.fileText.utf8).write(to: url, options: .atomic)
        persistCounter(scope)
    }

    private func nextNumber(_ scope: MemoryScope) -> Int {
        let highest = (entries(scope).map(\.number).max() ?? 0) + 1
        var kept = counters[scope] ?? 0
        if kept == 0, let url = url(scope)?.appendingPathComponent(Self.counterFile),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            kept = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return max(highest, kept)
    }

    private func persistCounter(_ scope: MemoryScope) {
        guard let url = url(scope)?.appendingPathComponent(Self.counterFile), let next = counters[scope] else { return }
        try? Data(String(next).utf8).write(to: url, options: .atomic)
    }

    private func url(_ scope: MemoryScope) -> URL? {
        guard let folder else { return nil }
        return scope.path.reduce(folder) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private func url(_ id: String, in scope: MemoryScope) -> URL? { url(scope)?.appendingPathComponent("\(id).md") }

    // MARK: Words and days

    private static func normalized(_ id: String) -> String { id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// 10a: the memory never keeps a secret (Y5). One line.
    private static func line(_ summary: String) -> String {
        SecretShield.shared.redact(summary).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(_ body: String) -> String {
        SecretShield.shared.redact(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func problem(summary: String, body: String) -> MemoryProblem? {
        if summary.count > summaryLimit { return .summaryTooLong(summary.count) }
        let tokens = ContextBudget.estimate(body)
        return tokens > bodyTokenLimit ? .bodyTooLong(tokens) : nil
    }

    nonisolated static func isStale(_ entry: MemoryEntry, now: Date = .now) -> Bool {
        guard let used = date(entry.used) else { return false }
        return used < now.addingTimeInterval(-Double(staleDays) * 86_400)
    }

    nonisolated static func day(_ date: Date) -> String { formatter.string(from: date) }

    nonisolated static func date(_ day: String) -> Date? { formatter.date(from: day) }

    private nonisolated static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
