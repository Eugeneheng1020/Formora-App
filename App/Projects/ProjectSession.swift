import AppKit
import Foundation
import Observation

/// The projects the app knows about, which one is open, and whether its folder is reachable.
@MainActor
@Observable
final class ProjectSession {
    enum Access: Equatable {
        case none
        case available(URL)
        case unavailable(ProjectFolders.UnavailableReason)
    }

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private let picker: FolderPicking
    @ObservationIgnored private var scopedURL: URL?

    private(set) var projects: [ProjectRecord] = []
    private(set) var current: ProjectRecord?
    private(set) var access: Access = .none

    init(store: ProjectStore, picker: FolderPicking) {
        self.store = store
        self.picker = picker
        reload()
        if let last = store.current { open(last) }
    }

    /// The open project's folder, when it is reachable.
    var accessibleRoot: URL? {
        if case .available(let url) = access { return url }
        return nil
    }

    // MARK: Opening

    /// Makes `record` the current project and starts access to its folder. An unreachable
    /// folder still opens the project (so the user sees why) with `access == .unavailable`.
    func open(_ record: ProjectRecord) {
        releaseAccess()
        access = resolveAccess(for: record, keepScope: true)
        current = record
        store.currentID = record.id
        store.markOpened(record)
        reload()
    }

    /// 「打开已有项目」: pick a folder, register it (or reuse its existing project), open it.
    @discardableResult
    func openExistingFolder() -> Bool {
        guard let record = pickExistingProject() else { return false }
        open(record)
        return true
    }

    /// The cold start holds the project until its last step (9f): picked and registered here, opened at the end.
    func pickExistingProject() -> ProjectRecord? {
        guard let picked = picker.pickFolder(title: "打开项目文件夹", prompt: "打开") else { return nil }
        let record = store.upsert(folder: picked.url, bookmark: picked.bookmark, summary: nil)
        reload()
        return record
    }

    /// Asks for the parent location of a new project.
    func pickLocation() -> PickedFolder? {
        picker.pickFolder(title: "选择项目位置", prompt: "选择")
    }

    /// 「新建项目」: creates `<location>/<name>`, registers and opens it.
    func createProject(named name: String, in location: PickedFolder, summary: String) throws {
        open(try registerNewProject(named: name, in: location, summary: summary))
    }

    /// 「新建项目」 in the cold start: the folder made and registered; it opens at the last step (9f).
    func registerNewProject(named name: String, in location: PickedFolder, summary: String) throws -> ProjectRecord {
        let folder = try ProjectFolders.createFolder(named: name, in: location.url)
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = store.upsert(folder: folder.url, bookmark: folder.bookmark, summary: trimmed)
        reload()
        return record
    }

    // MARK: Managing

    /// Removes the project from Formora only; its folder is not touched. Removing the open project
    /// moves to the next one, and removing the last one leaves no project open (→ launch flow).
    func remove(_ record: ProjectRecord) {
        let wasCurrent = record.id == current?.id
        store.remove(record)
        reload()
        guard wasCurrent else { return }
        releaseAccess()
        current = nil
        access = .none
        if let next = projects.first { open(next) }
    }

    func updateSummary(_ record: ProjectRecord, to summary: String) {
        store.updateSummary(record, to: summary)
        reload()
    }

    enum RelocateOutcome: Equatable {
        case cancelled
        case moved
        case failed(String)
    }

    /// Points a project at a different folder picked by the user; its name follows the folder.
    func relocate(_ record: ProjectRecord) -> RelocateOutcome {
        guard let picked = picker.pickFolder(title: "重新定位「\(record.name)」", prompt: "选择") else { return .cancelled }
        do {
            try store.relocate(record, to: picked.url, bookmark: picked.bookmark)
        } catch ProjectStoreError.folderAlreadyRegistered(let other) {
            return .failed("这个文件夹已经是项目「\(other)」了")
        } catch {
            return .failed(error.localizedDescription)
        }
        if record.id == current?.id { open(record) } else { reload() }
        return .moved
    }

    /// Shows the project's folder in Finder. Returns `false` if the folder is not reachable.
    @discardableResult
    func revealInFinder(_ record: ProjectRecord) -> Bool {
        if record.id == current?.id, case .available(let url) = access {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }
        guard case let .available(url, _, started) = ProjectFolders.resolve(bookmark: record.bookmark) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if started { url.stopAccessingSecurityScopedResource() }
        return true
    }

    /// Whether a project's folder is reachable right now, without keeping access open.
    func availability(of record: ProjectRecord) -> Access {
        if record.id == current?.id { return access }
        return resolveAccess(for: record, keepScope: false)
    }

    // MARK: Internals

    private func reload() {
        projects = store.all()
    }

    private func resolveAccess(for record: ProjectRecord, keepScope: Bool) -> Access {
        switch ProjectFolders.resolve(bookmark: record.bookmark) {
        case .unavailable(let reason):
            return .unavailable(reason)
        case let .available(url, refreshedBookmark, accessStarted):
            let path = ProjectStore.normalizedPath(url)
            if path != record.folderPath || refreshedBookmark != nil {
                store.updateLocation(record, path: path, bookmark: refreshedBookmark)
            }
            if keepScope {
                if accessStarted { scopedURL = url }
            } else if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
            return .available(url)
        }
    }

    private func releaseAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}
