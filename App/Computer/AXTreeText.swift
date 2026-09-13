import CoreGraphics
import Foundation

/// An accessibility tree as the model reads it (7j, C1; old phase 3): one line per element that means something,
/// each with its ref. Wrappers with no name, value or action give their place to their children; zero-size subtrees
/// are left out; depth, count and length are capped, and the end says so.
enum AXTreeText {
    static let depthLimit = 30
    static let nodeLimit = 400
    static let characterLimit = 12_000

    /// Actions that are only housekeeping: an element offering nothing else isn't worth a line for them.
    private static let quietActions: Set<String> = ["AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI"]
    /// Roles worth a line even when empty: things the model may type into or switch.
    private static let inputRoles: Set<String> = ["textfield", "textarea", "searchfield", "combobox", "checkbox", "radiobutton",
                                                  "popupbutton", "slider", "switch", "securetextfield"]

    struct Line {
        let node: AXNode
        let depth: Int
    }

    /// The lines of a tree, depth-first; `truncated` when a cap stopped it.
    static func lines(_ root: AXNode, maxDepth: Int = depthLimit) -> (lines: [Line], truncated: Bool) {
        var lines: [Line] = []
        var truncated = false
        func walk(_ node: AXNode, depth: Int, treeDepth: Int) {
            guard lines.count < nodeLimit else {
                truncated = true
                return
            }
            if treeDepth > 0, node.frame.width <= 0 || node.frame.height <= 0 { return }
            let shown = treeDepth == 0 || meaningful(node)
            if shown { lines.append(Line(node: node, depth: depth)) }
            guard treeDepth < maxDepth else {
                if !node.children.isEmpty { truncated = true }
                return
            }
            for child in node.children { walk(child, depth: shown ? depth + 1 : depth, treeDepth: treeDepth + 1) }
        }
        walk(root, depth: 0, treeDepth: 0)
        return (lines, truncated)
    }

    static func meaningful(_ node: AXNode) -> Bool {
        !node.title.isEmpty || !node.detail.isEmpty || !node.value.isEmpty || inputRoles.contains(role(node.role))
            || node.actions.contains { !quietActions.contains($0) }
    }

    /// `AXButton` → `button`.
    static func role(_ raw: String) -> String {
        (raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw).lowercased()
    }

    /// `AXPress` → `press`.
    static func action(_ raw: String) -> String {
        (raw.hasPrefix("AX") ? String(raw.dropFirst(2)) : raw).lowercased()
    }

    static func describe(_ node: AXNode, ref: String) -> String {
        var parts = [role(node.role)]
        if node.title.isEmpty, node.detail.isEmpty, !node.subrole.isEmpty { parts.append("(\(role(node.subrole)))") }
        if !node.title.isEmpty { parts.append("\"\(clip(node.title, 80))\"") }
        if !node.detail.isEmpty, node.detail != node.title { parts.append("desc=\"\(clip(node.detail, 80))\"") }
        parts.append("[ref=\(ref)]")
        if !node.value.isEmpty { parts.append("value=\"\(clip(node.value, 120))\"") }
        let frame = node.frame
        parts.append("(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)))")
        if !node.enabled { parts.append("disabled") }
        if node.focused { parts.append("focused") }
        let actions = node.actions.filter { !quietActions.contains($0) }.map(action)
        if !actions.isEmpty { parts.append("actions: " + actions.joined(separator: ",")) }
        return parts.joined(separator: " ")
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\"", with: "'")
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
