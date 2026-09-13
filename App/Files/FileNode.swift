import Foundation

/// One entry in a project folder.
struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isFolder: Bool
    /// Only meaningful for folders: `true` when the folder has no visible entries (the 「空」 tag).
    let isEmptyFolder: Bool

    var id: String { url.path }
}

/// A node placed in the visible list, with its indentation depth (the root is depth 0).
struct TreeRow: Identifiable, Hashable, Sendable {
    let node: FileNode
    let depth: Int

    var id: String { node.id }
}

/// Runs blocking work off the main actor and propagates cancellation to it.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let task = Task.detached(priority: .userInitiated, operation: work)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}
