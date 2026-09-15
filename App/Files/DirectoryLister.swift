import Foundation

/// Lists one folder: folders first, then files, each in Finder's name order. Hidden entries show too (user
/// 2026-09-15: `.formora`, `.github` are the project's) — only `.git` and `.DS_Store` never. Never writes.
enum DirectoryLister {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
    /// Never worth a row.
    static let alwaysHidden: Set<String> = [".git", ".DS_Store"]

    static func list(_ folder: URL) throws -> [FileNode] {
        // Listing a symlink itself fails with ENOTDIR, so list its target — but keep the children's
        // paths under the link, or they would collide with the real folder's children (same ids).
        let target = folder.resolvingSymlinksInPath()
        let names = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: keys)
            .map(\.lastPathComponent)
            .filter { !alwaysHidden.contains($0) }
        return names.map { name in
            let url = folder.appendingPathComponent(name)
            let isFolder = isFolder(url)
            return FileNode(url: url, name: name, isFolder: isFolder,
                            isEmptyFolder: isFolder && !hasVisibleEntries(url.resolvingSymlinksInPath()))
        }
        .sorted(by: finderOrder)
    }

    /// Symlinks to folders count as folders (they must expand). Packages — `.app`, Keynote, Pages,
    /// Numbers documents — count as files, the way Finder treats them.
    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isSymbolicLink == true {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue && !(url.resolvingSymlinksInPath().pathExtensionIsPackage)
        }
        if values?.isPackage == true { return false }
        return values?.isDirectory == true
    }

    static func hasVisibleEntries(_ folder: URL) -> Bool {
        let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
        while let entry = entries?.nextObject() as? URL {
            if !alwaysHidden.contains(entry.lastPathComponent) { return true }
        }
        return false
    }

    static func finderOrder(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

private extension URL {
    var pathExtensionIsPackage: Bool {
        (try? resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}
