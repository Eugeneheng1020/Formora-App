import Foundation

/// Conversation history on disk: one file per conversation plus an index that keeps their order, in the
/// profile's own folder (C19). History stays with the app, not the project, so moving or un-authorising a
/// project folder can't break it.
///
/// Carried over from the old app's performance review (2026-09-08): a change rewrites only the conversations
/// that changed plus the small index, on a background queue; while one write runs only the newest snapshot
/// waits behind it. Order of a write — changed files, removals, then the index — is what a crash may cut
/// safely: a file newer than the index is picked up on the next read, a listed file that is gone is skipped.
final class ConversationFiles: @unchecked Sendable {
    nonisolated static let indexName = "index.json"

    let folder: URL

    private let queue = DispatchQueue(label: "com.eugenecheng.formora.conversations", qos: .utility)
    private let lock = NSLock()
    /// What the folder holds as last written, so a save rewrites only what changed.
    private var lastWritten: [UUID: Conversation]?
    private var pending: [Conversation]?
    private var draining = false

    init(folder: URL) {
        self.folder = folder
    }

    var indexURL: URL { folder.appendingPathComponent(Self.indexName) }

    func fileURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    // MARK: Reading

    /// Index order, skipping files that are gone, then files written after the index, newest first.
    /// A file that doesn't decode is left where it is — it may be the only copy of someone's history.
    func load() -> [Conversation] {
        flush()
        let decoder = JSONDecoder()
        let ids = (try? Data(contentsOf: indexURL)).flatMap { try? decoder.decode([UUID].self, from: $0) } ?? []
        var loaded: [Conversation] = []
        var seen = Set<UUID>()
        for id in ids where seen.insert(id).inserted {
            if let data = try? Data(contentsOf: fileURL(id)), let conversation = try? decoder.decode(Conversation.self, from: data) {
                loaded.append(conversation)
            }
        }
        let indexDate = modificationDate(indexURL) ?? .distantPast
        var unlisted: [Conversation] = []
        for id in onDiskIDs() where !seen.contains(id) {
            guard let modified = modificationDate(fileURL(id)), modified > indexDate,
                  let data = try? Data(contentsOf: fileURL(id)),
                  let conversation = try? decoder.decode(Conversation.self, from: data) else { continue }
            unlisted.append(conversation)
        }
        unlisted.sort { $0.updatedAt > $1.updatedAt }
        let all = loaded + unlisted
        lock.withLock { lastWritten = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        return all
    }

    // MARK: Writing

    /// Writes now, on the caller's thread.
    @discardableResult
    func save(_ conversations: [Conversation]) -> Bool {
        let previous = lock.withLock { lastWritten }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            var written = Set<UUID>()
            for conversation in conversations where written.insert(conversation.id).inserted {
                if previous?[conversation.id] == conversation, FileManager.default.fileExists(atPath: fileURL(conversation.id).path) {
                    continue
                }
                // Atomic: a crash mid-write must not leave half a file where a conversation used to be.
                try encoder.encode(conversation).write(to: fileURL(conversation.id), options: .atomic)
            }
            let before = previous.map { Set($0.keys) } ?? onDiskIDs()
            for id in before.subtracting(written) { try? FileManager.default.removeItem(at: fileURL(id)) }
            try encoder.encode(conversations.map(\.id)).write(to: indexURL, options: .atomic)
            lock.withLock { lastWritten = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
            return true
        } catch {
            lock.withLock { lastWritten = nil }
            return false
        }
    }

    /// Hands the snapshot to the writer and returns at once; the disk always ends with the newest one.
    func saveInBackground(_ conversations: [Conversation]) {
        let start = lock.withLock {
            pending = conversations
            if draining { return false }
            draining = true
            return true
        }
        guard start else { return }
        queue.async { self.drain() }
    }

    /// Waits for every write scheduled so far — before a read, and on the way out.
    func flush() {
        queue.sync {}
    }

    private func drain() {
        while true {
            let next: [Conversation]? = lock.withLock {
                let snapshot = pending
                pending = nil
                if snapshot == nil { draining = false }
                return snapshot
            }
            guard let next else { return }
            save(next)
        }
    }

    private func onDiskIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".json") && $0 != Self.indexName }.compactMap { UUID(uuidString: String($0.dropLast(5))) })
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
