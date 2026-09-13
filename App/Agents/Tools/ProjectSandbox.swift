import Foundation

/// The project folder as the tools' whole world (7b, L6): paths are relative to it, and nothing that resolves
/// outside it — `..`, an absolute path elsewhere, a symlink pointing out — is read or written.
struct ProjectSandbox: Sendable {
    enum Problem: Error, Equatable {
        case empty
        case outside(String)

        var message: String {
            switch self {
            case .empty: "没有给出路径"
            case .outside(let path): "「\(path)」在项目文件夹之外。工具只能读写项目文件夹里的文件"
            }
        }
    }

    let root: URL
    /// Outside the project, folders the tools may still read — the Agent's enabled Skills (7f, F1) — by absolute path.
    let readRoots: [URL]
    /// …and write: a Skill this Agent created in the conversation (F2).
    let writeRoots: [URL]

    init(root: URL, readRoots: [URL] = [], writeRoots: [URL] = []) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.readRoots = readRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.writeRoots = writeRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    func resolve(_ raw: String, writing: Bool = false) throws -> URL {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw Problem.empty }
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let resolved = Self.resolvingExisting(candidate.standardizedFileURL)
        let others = writing ? writeRoots : readRoots + writeRoots
        guard contains(resolved) || others.contains(where: { Self.url(resolved, isIn: $0) }) else { throw Problem.outside(path) }
        return resolved
    }

    func contains(_ url: URL) -> Bool { Self.url(url, isIn: root) }

    private static func url(_ url: URL, isIn folder: URL) -> Bool {
        url.path == folder.path || url.path.hasPrefix(folder.path + "/")
    }

    /// The path as the project sees it; `.` for the folder itself.
    func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == root.path { return "." }
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
    }

    /// Symlinks resolved as far as the path exists, so a file about to be created under a linked folder is judged
    /// by where it would land.
    private static func resolvingExisting(_ url: URL) -> URL {
        var existing = url
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in rest { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL
    }
}
