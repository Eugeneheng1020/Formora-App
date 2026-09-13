import Foundation

/// Lists one folder the way Finder shows it: hidden files skipped, folders first, then files,
/// each in Finder's name order. Never writes.
enum DirectoryLister {
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]

    static func list(_ folder: URL) throws -> [FileNode] {
        // Listing a symlink itself fails with ENOTDIR, so list its target — but keep the children's
        // paths under the link, or they would collide with the real folder's children (same ids).
        let target = folder.resolvingSymlinksInPath()
        let names = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles])
            .map(\.lastPathComponent)
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
        let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        return entries?.nextObject() != nil
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
