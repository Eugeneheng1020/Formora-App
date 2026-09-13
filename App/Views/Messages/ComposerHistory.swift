import Foundation

/// ↑ / ↓ through the user's own messages in the composer (9b, Q3), as Claude Code and Codex do: in an empty composer ↑
/// brings back the latest, again the one before; ↓ goes forward, and past the latest leaves the composer empty. Only
/// while the composer is empty or still shows what was brought back — once it is edited, the keys move the caret.
struct ComposerHistory: Equatable {
    private(set) var index: Int?
    private var shown: String?

    /// The older message to show, or `nil` to let ↑ move the caret.
    mutating func older(current: String, history: [String]) -> String? {
        guard !history.isEmpty else { return nil }
        let next: Int
        if let index, current == shown {
            guard index > 0 else { return nil }
            next = index - 1
        } else {
            guard current.isEmpty else { return nil }
            next = history.count - 1
        }
        index = next
        shown = history[next]
        return history[next]
    }

    /// The newer message, `""` past the latest, or `nil` to let ↓ move the caret.
    mutating func newer(current: String, history: [String]) -> String? {
        guard let index, current == shown else { return nil }
        if index + 1 < history.count {
            self.index = index + 1
            shown = history[index + 1]
            return history[index + 1]
        }
        reset()
        return ""
    }

    mutating func reset() {
        index = nil
        shown = nil
    }
}
