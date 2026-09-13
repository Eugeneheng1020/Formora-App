import Foundation
import SwiftData

/// One project the user has opened or created. A project has no name of its own:
/// its name is always the name of its folder (user decision 2026-09-11).
@Model
final class ProjectRecord {
    @Attribute(.unique) var id: UUID
    /// Absolute, normalized path of the project folder.
    var folderPath: String
    /// Security-scoped bookmark to the folder. `nil` only if the system refused to create one;
    /// such a project is shown as unavailable until it is relocated.
    var bookmark: Data?
    /// Optional description the user typed ("项目简介").
    var summary: String
    var createdAt: Date
    var lastOpenedAt: Date?

    init(id: UUID = UUID(), folderPath: String, bookmark: Data?, summary: String = "", createdAt: Date = .now) {
        self.id = id
        self.folderPath = folderPath
        self.bookmark = bookmark
        self.summary = summary
        self.createdAt = createdAt
    }

    var name: String { (folderPath as NSString).lastPathComponent }
}
