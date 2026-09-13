import AppKit
import Foundation

/// A folder the user picked, plus the security-scoped bookmark that lets the sandboxed app
/// reach it again after relaunch.
struct PickedFolder: Equatable, Sendable {
    let url: URL
    let bookmark: Data?
}

@MainActor
protocol FolderPicking {
    func pickFolder(title: String, prompt: String) -> PickedFolder?
}

enum ProjectFolderError: Error, Equatable {
    case nameProblem(ProjectNameRule.Problem)
    case alreadyExists
    case cannotCreate(String)

    var message: String {
        switch self {
        case .nameProblem(let problem): ProjectNameRule.message(for: problem)
        case .alreadyExists: "这个位置已经有同名文件夹，换个名称或位置"
        case .cannotCreate(let reason): "无法创建文件夹：\(reason)"
        }
    }
}

enum ProjectFolders {
    enum UnavailableReason: Equatable, Sendable {
        case noBookmark
        case cannotResolve
        case missing
        case inTrash
        case accessDenied

        var message: String {
            switch self {
            case .noBookmark, .cannotResolve: "找不到这个文件夹的访问授权"
            case .missing: "文件夹已被删除或移走"
            case .inTrash: "文件夹在废纸篓里"
            case .accessDenied: "没有访问这个文件夹的权限"
            }
        }
    }

    enum Resolution: Equatable {
        /// `accessStarted` means the caller now owns a security scope and must stop it.
        case available(url: URL, refreshedBookmark: Data?, accessStarted: Bool)
        case unavailable(UnavailableReason)
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Creates `<parent>/<name>` and bookmarks it while access to `parent` is held.
    static func createFolder(named raw: String, in parent: URL) throws -> PickedFolder {
        if let problem = ProjectNameRule.problem(with: raw) { throw ProjectFolderError.nameProblem(problem) }
        let didStart = parent.startAccessingSecurityScopedResource()
        defer { if didStart { parent.stopAccessingSecurityScopedResource() } }

        let url = parent.appendingPathComponent(ProjectNameRule.normalized(raw), isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { throw ProjectFolderError.alreadyExists }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw ProjectFolderError.cannotCreate(error.localizedDescription)
        }
        return PickedFolder(url: url, bookmark: makeBookmark(for: url))
    }

    /// Resolves a stored bookmark and starts security-scoped access. Bookmarks follow moves,
    /// so the returned URL may differ from the stored path; a stale bookmark is refreshed.
    static func resolve(bookmark: Data?) -> Resolution {
        guard let bookmark else { return .unavailable(.noBookmark) }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return .unavailable(.cannotResolve)
        }
        let started = url.startAccessingSecurityScopedResource()
        func fail(_ reason: UnavailableReason) -> Resolution {
            if started { url.stopAccessingSecurityScopedResource() }
            return .unavailable(reason)
        }
        if url.pathComponents.contains(".Trash") { return fail(.inTrash) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return fail(.missing)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return fail(.accessDenied) }
        return .available(url: url, refreshedBookmark: isStale ? makeBookmark(for: url) : nil, accessStarted: started)
    }
}

/// The real picker: a system NSOpenPanel limited to one folder.
struct OpenPanelFolderPicker: FolderPicking {
    func pickFolder(title: String, prompt: String) -> PickedFolder? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return PickedFolder(url: url, bookmark: ProjectFolders.makeBookmark(for: url))
    }
}

/// Verification hook for named profiles: returns `<root>/<name>` (created on demand) without a system panel,
/// so UI tests and screenshots can walk the flow. Selected with `-FormoraPickFolder <name>`.
struct ProfileFolderPicker: FolderPicking {
    let root: URL
    let name: String

    func pickFolder(title: String, prompt: String) -> PickedFolder? {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return PickedFolder(url: url, bookmark: ProjectFolders.makeBookmark(for: url))
    }
}
