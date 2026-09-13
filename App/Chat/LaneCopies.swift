import Foundation

/// 10l: members working side by side, each in a copy of the project (Codex `worktree/src/lib.rs`, omp task isolation's
/// `rcopy`), so two of them never write over each other. The copy is a clone — APFS shares the bytes until one side
/// changes them — in Formora's own folder, without `.git` (a lane doesn't commit). When the member is done its changes
/// come back: a file the project still has as it was when the copy was made takes the member's version; one changed
/// meanwhile — by the user, or by a member who came back first — isn't overwritten: the member's version is kept beside
/// it. No git needed: most projects here are folders of documents.
enum LaneCopies {
    struct Stamp: Equatable, Sendable {
        var size: Int
        var modified: Date
    }

    struct Copy: Sendable {
        /// Where the member works.
        let root: URL
        /// The project.
        let source: URL
        /// Every file of the project when the copy was made: what "unchanged" means when the changes come back.
        let manifest: [String: Stamp]
    }

    struct Merge: Equatable, Sendable {
        struct Kept: Equatable, Sendable {
            var path: String
            var copy: String
        }

        var applied: [String] = []
        var removed: [String] = []
        /// The member's version kept beside a file changed meanwhile.
        var kept: [Kept] = []

        var isEmpty: Bool { applied.isEmpty && removed.isEmpty && kept.isEmpty }
    }

    /// Past this many files the member works in the project itself, as before: a copy would take too long.
    static let fileLimit = 20_000
    static let skipped: Set<String> = [".git"]
    /// One merge at a time: two members coming back at once must not both find a file unchanged.
    private static let queue = DispatchQueue(label: "formora.lane-copies")

    /// A copy of `source` for the lane `id` under `folder`; `nil` when the project is too big or copying fails.
    static func make(from source: URL, id: UUID, in folder: URL, limit: Int = fileLimit) -> Copy? {
        guard let manifest = stamps(source, limit: limit) else { return nil }
        let root = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        let files = FileManager.default
        try? files.removeItem(at: root)
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            for item in try files.contentsOfDirectory(atPath: source.path) where !skipped.contains(item) {
                try files.copyItem(at: source.appendingPathComponent(item), to: root.appendingPathComponent(item))
            }
        } catch {
            try? files.removeItem(at: root)
            return nil
        }
        return Copy(root: root, source: source, manifest: manifest)
    }

    /// The member's changes into the project, one merge at a time.
    static func mergeSerially(_ copy: Copy, name: String) async -> Merge {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: merge(copy, name: name)) }
        }
    }

    /// What the member changed, added and removed in its copy, brought into the project (see the type).
    static func merge(_ copy: Copy, name: String) -> Merge {
        var merge = Merge()
        guard let now = stamps(copy.root, limit: .max) else { return merge }
        let files = FileManager.default
        for (path, stamp) in now.sorted(by: { $0.key < $1.key }) {
            let before = copy.manifest[path]
            // Untouched in the copy: a clone keeps its size and date.
            guard before != stamp else { continue }
            let lane = copy.root.appendingPathComponent(path)
            let target = copy.source.appendingPathComponent(path)
            if Self.stamp(of: target) == before {
                // As it was when the copy was made (or still absent, for a new file): the member's version.
                do {
                    try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                    try files.copyItem(at: lane, to: target)
                    merge.applied.append(path)
                } catch {
                    if let kept = keepBeside(lane, path: path, name: name, in: copy.source) { merge.kept.append(kept) }
                }
            } else if let mine = try? Data(contentsOf: lane), let theirs = try? Data(contentsOf: target), mine == theirs {
                continue
            } else if let kept = keepBeside(lane, path: path, name: name, in: copy.source) {
                merge.kept.append(kept)
            }
        }
        for (path, stamp) in copy.manifest.sorted(by: { $0.key < $1.key }) where now[path] == nil {
            let target = copy.source.appendingPathComponent(path)
            if Self.stamp(of: target) == stamp, (try? files.removeItem(at: target)) != nil { merge.removed.append(path) }
        }
        return merge
    }

    /// The copy gone — merged, or never to be.
    static func remove(_ copy: Copy) {
        try? FileManager.default.removeItem(at: copy.root)
    }

    /// The words under the member's reply: what came back, and what was kept beside.
    static func note(_ merge: Merge) -> String? {
        var parts: [String] = []
        let changed = merge.applied + merge.removed
        if !changed.isEmpty {
            let names = changed.prefix(4).joined(separator: "、") + (changed.count > 4 ? " 等 \(changed.count) 个文件" : "")
            parts.append("改动已合回项目：\(names)")
        }
        for kept in merge.kept.prefix(4) {
            parts.append("\(kept.path) 在它做的时候被改过，没有覆盖；它的版本存成了 \(kept.copy)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    // MARK: Files

    /// Every file under `root` but `.git`, by its path from there; `nil` past `limit`.
    static func stamps(_ root: URL, limit: Int) -> [String: Stamp]? {
        let base = root.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [:] }
        var out: [String: Stamp] = [:]
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            out[String(path.dropFirst(base.count + 1))] = Stamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
            if out.count > limit { return nil }
        }
        return out
    }

    private static func stamp(of url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true else { return nil }
        return Stamp(size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
    }

    /// `PRD/a.md` from 研发 → `PRD/a（研发的版本）.md`, numbered if that is taken.
    private static func keepBeside(_ lane: URL, path: String, name: String, in source: URL) -> Merge.Kept? {
        let who = name.replacingOccurrences(of: "/", with: "／")
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent().relativePath
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let prefix = folder == "." || folder.isEmpty ? "" : folder + "/"
        for number in 1...50 {
            let candidate = prefix + stem + "（\(who)的版本" + (number == 1 ? "" : " \(number)") + "）" + ext
            let target = source.appendingPathComponent(candidate)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: lane, to: target)
                return Merge.Kept(path: path, copy: candidate)
            } catch {
                return nil
            }
        }
        return nil
    }
}
