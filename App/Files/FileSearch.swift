import Foundation

/// File-name search over the whole project tree (design spec §5):
/// every hit keeps its ancestor folders, and collapse state is ignored.
enum FileSearch {
    struct Outcome: Equatable, Sendable {
        let rows: [TreeRow]
        /// The walk stopped at `limit` entries; the result may be incomplete.
        let truncated: Bool
    }

    static let limit = 20_000

    /// trim + NFKC + lowercase, so full-width/half-width and case differences still match.
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.lowercased()
    }

    static func search(root: FileNode, query rawQuery: String, limit: Int = FileSearch.limit,
                       isCancelled: () -> Bool = { Task.isCancelled }) -> Outcome {
        let query = normalize(rawQuery)
        guard !query.isEmpty else { return Outcome(rows: [], truncated: false) }
        var visited = 0
        var truncated = false
        var seenFolders = Set<String>()

        func visit(_ node: FileNode, depth: Int) -> [TreeRow] {
            if truncated || isCancelled() { return [] }
            visited += 1
            if visited > limit {
                truncated = true
                return []
            }
            var childRows: [TreeRow] = []
            if node.isFolder, seenFolders.insert(node.url.resolvingSymlinksInPath().path).inserted,
               let children = try? DirectoryLister.list(node.url) {
                for child in children { childRows += visit(child, depth: depth + 1) }
            }
            let isHit = depth > 0 && normalize(node.name).contains(query)
            guard isHit || !childRows.isEmpty else { return [] }
            return [TreeRow(node: node, depth: depth)] + childRows
        }

        return Outcome(rows: visit(root, depth: 0), truncated: truncated)
    }
}
