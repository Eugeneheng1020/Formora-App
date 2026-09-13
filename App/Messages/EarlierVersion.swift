import Foundation

/// 10e: what an edited message replaced — it and everything after it, as the thread had them — kept to be read under the
/// line that stands in their place. Never sent to a model again, never resumed: going back is going on from there.
struct EarlierVersion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var replacedAt: Date
    var messages: [Message]
}
