import CoreGraphics
import Foundation

/// 自主操控电脑 (user 2026-09-15): what the session sees for itself after every act — frames compared locally until the
/// screen settles, the window's tree before and after, and the step's own expectation checked — so the model gets the
/// result without asking for it, and one screenshot per batch instead of one per step.

/// A frame's small grey signature: enough to tell whether the screen is still changing. Never sent to a model.
struct FrameSignature: Equatable, Sendable {
    let width: Int
    let height: Int
    let luma: [UInt8]

    /// A pixel counts as changed past this much grey (of 255): a shadow or a blink stays below it.
    static let pixelStep = 12

    /// The share of pixels that changed, 0 (the same) to 1; frames of different sizes always differ. A share, not a
    /// mean: a small panel opening over a dark desktop moves few pixels, but moves them a lot (demo 2026-09-15: Raycast).
    func difference(to other: FrameSignature) -> Double {
        guard width == other.width, height == other.height, luma.count == other.luma.count, !luma.isEmpty else { return 1 }
        var moved = 0
        for (a, b) in zip(luma, other.luma) where abs(Int(a) - Int(b)) > Self.pixelStep { moved += 1 }
        return Double(moved) / Double(luma.count)
    }
}

enum Settle {
    /// Below this share of moved pixels the two frames are the same picture to the eye (a cursor blink) — not a change.
    static let threshold = 0.003

    /// The pacing: a quarter second a frame, three seconds at most, an expectation given up to two more.
    struct Timing: Equatable, Sendable {
        var interval: Double = 0.25
        var limit: Double = 3
        var expectLimit: Double = 2
    }

    static func isStill(_ a: FrameSignature, _ b: FrameSignature) -> Bool { a.difference(to: b) < threshold }
}

/// One line of an accessibility tree as it is compared: who it is (role, title, description), what it holds.
struct TreeLine: Equatable, Sendable {
    let identity: String
    let value: String
    let text: String

    init(identity: String, value: String, text: String) {
        self.identity = identity
        self.value = value
        self.text = text
    }

    init(_ node: AXNode) {
        let role = AXTreeText.role(node.role)
        let name = node.title.isEmpty ? node.detail : node.title
        identity = "\(role)|\(node.title)|\(node.detail)"
        value = node.value
        let shown = node.value.count > 40 ? String(node.value.prefix(40)) + "…" : node.value
        text = (role + (name.isEmpty ? "" : " " + name)) + (shown.isEmpty ? "" : " = " + shown)
    }
}

/// What an act changed in a window: lines that appeared, lines that went, values that changed.
struct TreeDiff: Equatable, Sendable {
    static let limit = 8

    var added: [String] = []
    var removed: [String] = []
    var changed: [String] = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    static func compare(before: [TreeLine], after: [TreeLine]) -> TreeDiff {
        var diff = TreeDiff()
        var earlier: [String: [TreeLine]] = [:]
        for line in before { earlier[line.identity, default: []].append(line) }
        var later: [String: [TreeLine]] = [:]
        for line in after { later[line.identity, default: []].append(line) }
        for line in after {
            guard let olds = earlier[line.identity], let old = olds.first else {
                diff.added.append(line.text)
                continue
            }
            if !olds.contains(where: { $0.value == line.value }), olds.count == 1 {
                diff.changed.append("\(line.text.components(separatedBy: " = ").first ?? line.text)：「\(old.value)」→「\(line.value)」")
            }
            earlier[line.identity] = Array(olds.dropFirst())
        }
        for line in before where later[line.identity] == nil { diff.removed.append(line.text) }
        return diff
    }

    /// 「新出现：a；消失：b；变了：c」, each part cut at eight with how many more.
    var text: String {
        func part(_ name: String, _ lines: [String]) -> String? {
            guard !lines.isEmpty else { return nil }
            let shown = lines.prefix(Self.limit).joined(separator: "、")
            return name + shown + (lines.count > Self.limit ? "…还有 \(lines.count - Self.limit) 处" : "")
        }
        return [part("新出现：", added), part("消失：", removed), part("变了：", changed)].compactMap { $0 }.joined(separator: "；")
    }
}

/// What a step should leave behind, as its `expect` says: checked by the session, met or not.
struct Expectation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case appears(role: String?, title: String?, value: String?)
        case gone(role: String?, title: String?, value: String?)
        case window(app: String?, title: String?)
        case value(ref: String, equals: String?, contains: String?)
        case changed
    }

    let kind: Kind
    let description: String

    /// `nil` without an `expect`; a problem the model reads when it can't be understood.
    static func parse(_ raw: Any?) throws -> Expectation? {
        guard let raw else { return nil }
        guard let object = raw as? [String: Any] else {
            throw DesktopProblem("expect 要写成对象：{\"appears\":{\"title\":\"…\"}}、{\"gone\":…}、{\"window\":{\"app\":\"…\"}}、{\"value\":{\"ref\":\"e1\",\"contains\":\"…\"}} 或 {\"changed\":true}")
        }
        func field(_ dict: [String: Any], _ key: String) -> String? {
            (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func element(_ key: String) throws -> (String?, String?, String?) {
            guard let dict = object[key] as? [String: Any] else { throw DesktopProblem("expect.\(key) 要写成对象：{\"role\":…, \"title\":…, \"value\":…}") }
            let parts = (field(dict, "role"), field(dict, "title"), field(dict, "value"))
            guard parts.0 != nil || parts.1 != nil || parts.2 != nil else { throw DesktopProblem("expect.\(key) 至少要给 role、title、value 之一") }
            return parts
        }
        func words(_ role: String?, _ title: String?, _ value: String?) -> String {
            [role, title.map { "「\($0)」" }, value.map { "值含「\($0)」" }].compactMap { $0 }.joined(separator: "")
        }
        if object["appears"] != nil {
            let (role, title, value) = try element("appears")
            return Expectation(kind: .appears(role: role, title: title, value: value), description: "出现 " + words(role, title, value))
        }
        if object["gone"] != nil {
            let (role, title, value) = try element("gone")
            return Expectation(kind: .gone(role: role, title: title, value: value), description: "消失 " + words(role, title, value))
        }
        if let dict = object["window"] as? [String: Any] {
            let app = field(dict, "app"), title = field(dict, "title")
            guard app != nil || title != nil else { throw DesktopProblem("expect.window 要给 app 或 title") }
            return Expectation(kind: .window(app: app, title: title), description: "出现窗口 " + [app, title].compactMap { $0 }.joined(separator: " "))
        }
        if let dict = object["value"] as? [String: Any] {
            guard let ref = field(dict, "ref") else { throw DesktopProblem("expect.value 要给 ref") }
            let equals = field(dict, "equals"), contains = field(dict, "contains")
            guard equals != nil || contains != nil else { throw DesktopProblem("expect.value 要给 equals 或 contains") }
            return Expectation(kind: .value(ref: ref, equals: equals, contains: contains),
                               description: "\(ref) 的值" + (equals.map { "等于「\($0)」" } ?? "含「\(contains ?? "")」"))
        }
        if object["changed"] != nil {
            return Expectation(kind: .changed, description: "画面有变化")
        }
        throw DesktopProblem("expect 只认 appears、gone、window、value、changed")
    }

    /// Whether a tree has an element like this.
    static func matches(_ root: AXNode, role: String?, title: String?, value: String?) -> Bool {
        let role = role?.lowercased(), title = title?.lowercased(), value = value?.lowercased()
        return AXTreeText.lines(root).lines.contains { line in
            (role.map { AXTreeText.role(line.node.role).contains($0) } ?? true)
                && (title.map { (line.node.title + " " + line.node.detail).lowercased().contains($0) } ?? true)
                && (value.map { line.node.value.lowercased().contains($0) } ?? true)
        }
    }
}
