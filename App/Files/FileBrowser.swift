import Foundation
import Observation

/// The open project's folder as a tree: which folders are expanded, what is selected, and search.
/// Listing happens off the main actor; only results land here.
@MainActor
@Observable
final class FileBrowser {
    let root: FileNode

    private(set) var expanded: Set<String>
    private(set) var listings: [String: [FileNode]] = [:]
    private(set) var failedFolders: Set<String> = []
    /// The file shown in the preview pane.
    private(set) var selectedFileID: String?
    /// Keyboard focus in the tree (files and folders).
    var focusedID: String?
    /// The entry the user last clicked or moved to, file or folder (user 2026-09-22): what the files pane's chat carries.
    private(set) var lastChosen: FileNode?

    /// 预览 or 源码 for HTML files. Kept while moving between files, so reading several pages' source
    /// doesn't need a click per file; a newly opened project starts on 预览.
    var htmlView: HTMLViewMode = .rendered

    var searchText = ""
    /// `nil` while not searching.
    private(set) var searchOutcome: FileSearch.Outcome?

    init(rootURL: URL) {
        root = FileNode(url: rootURL, name: rootURL.lastPathComponent, isFolder: true, isEmptyFolder: false)
        expanded = [root.id]
    }

    // MARK: Rows

    var isSearching: Bool { !FileSearch.normalize(searchText).isEmpty }

    /// What the list shows: search results while searching, otherwise the expanded tree.
    var visibleRows: [TreeRow] {
        if isSearching { return searchOutcome?.rows ?? [] }
        var rows: [TreeRow] = []
        func append(_ node: FileNode, depth: Int) {
            rows.append(TreeRow(node: node, depth: depth))
            guard node.isFolder, expanded.contains(node.id) else { return }
            for child in listings[node.id] ?? [] { append(child, depth: depth + 1) }
        }
        append(root, depth: 0)
        return rows
    }

    /// The project folder has been read and has nothing visible in it.
    var isEmptyProject: Bool { listings[root.id]?.isEmpty == true }

    var selectedNode: FileNode? {
        guard let id = selectedFileID else { return nil }
        return node(withID: id)
    }

    func isExpanded(_ node: FileNode) -> Bool {
        isSearching ? node.isFolder : expanded.contains(node.id)
    }

    // MARK: Loading

    /// Re-reads every expanded folder (keeps expansion and selection).
    func refresh() async {
        for id in expanded {
            guard let folder = node(withID: id) ?? (id == root.id ? root : nil) else { continue }
            await load(folder)
        }
    }

    func setExpanded(_ folder: FileNode, _ isExpanded: Bool) async {
        guard folder.isFolder else { return }
        if isExpanded {
            expanded.insert(folder.id)
            await load(folder)
        } else {
            expanded.remove(folder.id)
        }
    }

    func toggle(_ folder: FileNode) {
        let open = !expanded.contains(folder.id)
        Task { await setExpanded(folder, open) }
    }

    private func load(_ folder: FileNode) async {
        let url = folder.url
        let result: [FileNode]? = await offMain { try? DirectoryLister.list(url) }
        if let result {
            listings[folder.id] = result
            failedFolders.remove(folder.id)
        } else {
            listings[folder.id] = []
            failedFolders.insert(folder.id)
        }
    }

    // MARK: Selection

    func select(_ node: FileNode) {
        focusedID = node.id
        // The project row only folds the tree: it isn't an entry to carry (`@.` is no token).
        if node.id != root.id { lastChosen = node }
        if node.isFolder {
            toggle(node)
        } else {
            selectedFileID = node.id
        }
    }

    /// Moves keyboard focus up or down the visible rows; files become the previewed file.
    func moveFocus(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == focusedID } ?? (delta > 0 ? -1 : rows.count)
        let next = rows[min(max(current + delta, 0), rows.count - 1)].node
        focusedID = next.id
        if !next.isFolder {
            selectedFileID = next.id
            lastChosen = next
        }
    }

    /// ← collapses the focused folder (or jumps to its parent); → expands it.
    func expandFocused(_ open: Bool) {
        guard let id = focusedID, let node = node(withID: id) ?? (id == root.id ? root : nil) else { return }
        if node.isFolder, expanded.contains(node.id) != open {
            Task { await setExpanded(node, open) }
        } else if !open, let parent = parentID(of: id) {
            focusedID = parent
        }
    }

    /// Expands the folders on the way to `relativePath` (relative to the project folder) and selects it.
    /// Used for "show in Files" jumps.
    func reveal(relativePath: String) async {
        searchText = ""
        searchOutcome = nil
        var current = root
        let parts = relativePath.split(separator: "/").map(String.init)
        for (index, name) in parts.enumerated() {
            await setExpanded(current, true)
            guard let child = listings[current.id]?.first(where: { $0.name == name }) else { return }
            if index == parts.count - 1 {
                focusedID = child.id
                lastChosen = child
                if child.isFolder { await setExpanded(child, true) } else { selectedFileID = child.id }
            } else {
                current = child
            }
        }
    }

    // MARK: Search

    /// Debounced (150 ms) and cancellable: call from `.task(id: searchText)`.
    func performSearch() async {
        guard isSearching else {
            searchOutcome = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let root = root, query = searchText
        let outcome = await offMain { FileSearch.search(root: root, query: query) }
        guard !Task.isCancelled else { return }
        searchOutcome = outcome
    }

    // MARK: Lookup

    func node(withID id: String) -> FileNode? {
        if id == root.id { return root }
        for children in listings.values {
            if let hit = children.first(where: { $0.id == id }) { return hit }
        }
        return searchOutcome?.rows.first { $0.id == id }?.node
    }

    private func parentID(of id: String) -> String? {
        guard id != root.id else { return nil }
        let parent = (id as NSString).deletingLastPathComponent
        return parent.hasPrefix(root.id) ? parent : nil
    }

    /// Path shown under the preview title: relative to the project, starting with its name.
    func displayPath(of node: FileNode) -> String {
        let rootPath = root.url.path
        guard node.url.path.hasPrefix(rootPath + "/") else { return node.name }
        return root.name + String(node.url.path.dropFirst(rootPath.count))
    }
}
