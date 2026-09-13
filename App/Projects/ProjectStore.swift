import Foundation
import SwiftData

enum ProjectStoreError: Error, Equatable {
    /// Another project already points at this folder.
    case folderAlreadyRegistered(String)
}

/// Persistence for projects (SwiftData) plus which project is current (profile defaults).
/// Main-actor only: SwiftData's `ModelContext` is not `Sendable`.
@MainActor
final class ProjectStore {
    static let currentProjectKey = "formora.currentProjectID"
    /// Not `Formora.store`: that file belongs to the previous app and has a different schema.
    static let storeFileName = "Workspace.store"

    /// Held on purpose: a `ModelContext` does not keep its container alive, and fetching through a
    /// context whose container was released traps inside SwiftData (seen in VerificationHooksTests).
    private let container: ModelContainer
    private let context: ModelContext
    private let defaults: UserDefaults

    init(container: ModelContainer, defaults: UserDefaults) {
        self.container = container
        self.context = container.mainContext
        self.defaults = defaults
    }

    /// `storeURL == nil` gives an in-memory store (tests). Adding a model type to this list is a lightweight
    /// migration SwiftData does on open (covered by `AgentStoreTests.persistenceAndMigration`); changing an
    /// existing type's stored properties needs a versioned schema.
    static func makeContainer(storeURL: URL?) throws -> ModelContainer {
        let schema = Schema([ProjectRecord.self, AgentRecord.self])
        let configuration = storeURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Pure path arithmetic — safe from any thread.
    nonisolated static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Reading

    /// Most recently opened first; never-opened projects after them, newest first.
    func all() -> [ProjectRecord] {
        let records = (try? context.fetch(FetchDescriptor<ProjectRecord>())) ?? []
        return records.sorted { a, b in
            switch (a.lastOpenedAt, b.lastOpenedAt) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.createdAt > b.createdAt
            }
        }
    }

    func record(id: UUID) -> ProjectRecord? {
        all().first { $0.id == id }
    }

    func record(forFolder url: URL) -> ProjectRecord? {
        let path = Self.normalizedPath(url)
        return all().first { $0.folderPath == path }
    }

    // MARK: Current project

    var currentID: UUID? {
        get { defaults.string(forKey: Self.currentProjectKey).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue { defaults.set(newValue.uuidString, forKey: Self.currentProjectKey) }
            else { defaults.removeObject(forKey: Self.currentProjectKey) }
        }
    }

    /// The current project, only if it still exists; a dangling id is cleared.
    var current: ProjectRecord? {
        guard let id = currentID else { return nil }
        guard let record = record(id: id) else {
            currentID = nil
            return nil
        }
        return record
    }

    // MARK: Writing

    /// Registers a folder, or refreshes the existing project for that folder instead of duplicating it.
    /// A `nil` bookmark or summary never wipes a value already stored.
    @discardableResult
    func upsert(folder: URL, bookmark: Data?, summary: String?) -> ProjectRecord {
        if let existing = record(forFolder: folder) {
            if let bookmark { existing.bookmark = bookmark }
            if let summary { existing.summary = summary }
            save()
            return existing
        }
        let record = ProjectRecord(folderPath: Self.normalizedPath(folder), bookmark: bookmark, summary: summary ?? "")
        context.insert(record)
        save()
        return record
    }

    func remove(_ record: ProjectRecord) {
        if currentID == record.id { currentID = nil }
        context.delete(record)
        save()
    }

    func updateSummary(_ record: ProjectRecord, to summary: String) {
        record.summary = summary
        save()
    }

    /// Points a project at another folder. Its name follows the new folder.
    func relocate(_ record: ProjectRecord, to folder: URL, bookmark: Data?) throws {
        let path = Self.normalizedPath(folder)
        if let other = all().first(where: { $0.folderPath == path }), other.id != record.id {
            throw ProjectStoreError.folderAlreadyRegistered(other.name)
        }
        record.folderPath = path
        record.bookmark = bookmark
        save()
    }

    /// Follows a folder the system says has moved (bookmark resolved to a new path).
    func updateLocation(_ record: ProjectRecord, path: String, bookmark: Data?) {
        record.folderPath = path
        if let bookmark { record.bookmark = bookmark }
        save()
    }

    func markOpened(_ record: ProjectRecord, at date: Date = .now) {
        record.lastOpenedAt = date
        save()
    }

    private func save() {
        try? context.save()
    }
}
