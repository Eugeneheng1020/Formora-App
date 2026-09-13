import Foundation

/// The MCP layer's `JSONValue`, bridged to Foundation's objects: a hooks.json goes through `JSONSerialization`, and
/// keeps every field Formora doesn't use.
extension JSONValue {
    init(_ value: Any) {
        switch value {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let list as [Any]:
            self = .array(list.map(JSONValue.init))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init))
        default:
            self = .null
        }
    }

    var any: Any {
        switch self {
        case .string(let text): return text
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 { return Int(number) }
            return number
        case .bool(let flag): return flag
        case .null: return NSNull()
        case .array(let list): return list.map(\.any)
        case .object(let object): return object.mapValues(\.any)
        }
    }
}

/// The moments a hook can run at (7b′, H2): Claude Code's names, the five the agent core has so far.
enum HookEvent: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
    /// A delegated subtask's start and end (7g, S2).
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"

    var label: String {
        switch self {
        case .sessionStart: "对话开始时"
        case .userPromptSubmit: "发送消息时"
        case .preToolUse: "工具执行前"
        case .postToolUse: "工具执行后"
        case .stop: "回复结束时"
        case .subagentStart: "子任务开始时"
        case .subagentStop: "子任务结束时"
        }
    }

    /// When it runs and what it can change, for the editor.
    var note: String {
        switch self {
        case .sessionStart: "新对话第一次交给 Agent 之前。命令输出的文字会作为背景交给 Agent。"
        case .userPromptSubmit: "你发出一条消息时。退出码 2 会拦下这条消息；命令输出的文字会作为背景交给 Agent。"
        case .preToolUse: "Agent 调用工具之前。退出码 2 会拦下这一步，并把理由告诉 Agent。"
        case .postToolUse: "工具执行成功之后，比如写完文件自动格式化。退出码 2 会把理由反馈给 Agent。"
        case .stop: "Agent 这一轮回复完。退出码 2 会让它接着做，最多 3 次。"
        case .subagentStart: "委派出去的子任务开始之前。命令输出的文字会作为背景交给帮手。"
        case .subagentStop: "委派出去的子任务回复完。退出码 2 会让帮手接着做，最多 3 次。"
        }
    }

    /// Matched against the tool's name (H2).
    var usesToolMatcher: Bool { self == .preToolUse || self == .postToolUse }
    /// Whether exit code 2 or `"decision": "block"` changes what happens (H6).
    var canBlock: Bool { self != .sessionStart && self != .subagentStart }
    /// Claude Code's shorter wait before a message goes (H7).
    var defaultTimeout: Int { self == .userPromptSubmit ? 30 : 60 }
}

/// What a URL hook posts (H5): the event as JSON, or a text message a chat robot takes.
enum WebhookFormat: String, CaseIterable, Sendable {
    case raw, feishu, wecom, dingtalk, slack

    var label: String {
        switch self {
        case .raw: "原样 JSON"
        case .feishu: "飞书机器人"
        case .wecom: "企业微信机器人"
        case .dingtalk: "钉钉机器人"
        case .slack: "Slack"
        }
    }

    func body(_ input: HookInput) -> Data {
        let payload: [String: Any]
        switch self {
        case .raw: payload = input.payload
        case .feishu: payload = ["msg_type": "text", "content": ["text": input.message]]
        case .wecom, .dingtalk: payload = ["msgtype": "text", "text": ["content": input.message]]
        case .slack: payload = ["text": input.message]
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}

/// One thing a hook does: run a command, or post to a URL.
struct HookHandler: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case command(String)
        case http(url: String, format: WebhookFormat)
        /// Claude Code's other kinds (prompt, agent, mcp_tool): kept in the file, listed, not run.
        case unsupported(String)
    }

    var kind: Kind
    /// Seconds; the moment's default when missing (H7).
    var timeout: Int?
    var headers: [String: String] = [:]
    /// Fields Formora doesn't use, kept as they were.
    var extra: [String: JSONValue] = [:]

    init(kind: Kind, timeout: Int? = nil, headers: [String: String] = [:], extra: [String: JSONValue] = [:]) {
        self.kind = kind
        self.timeout = timeout
        self.headers = headers
        self.extra = extra
    }

    init(json: [String: JSONValue]) {
        var fields = json
        let type = fields.removeValue(forKey: "type")?.string ?? "command"
        timeout = fields.removeValue(forKey: "timeout")?.int
        switch type {
        case "command":
            kind = .command(fields.removeValue(forKey: "command")?.string ?? "")
        case "http":
            let url = fields.removeValue(forKey: "url")?.string ?? ""
            let format = fields.removeValue(forKey: "format")?.string.flatMap(WebhookFormat.init) ?? .raw
            headers = fields.removeValue(forKey: "headers")?.object?.compactMapValues(\.string) ?? [:]
            kind = .http(url: url, format: format)
        default:
            kind = .unsupported(type)
        }
        extra = fields
    }

    var json: [String: Any] {
        var object = extra.mapValues(\.any)
        switch kind {
        case .command(let command):
            object["type"] = "command"
            object["command"] = command
        case let .http(url, format):
            object["type"] = "http"
            object["url"] = url
            if format != .raw { object["format"] = format.rawValue }
            if !headers.isEmpty { object["headers"] = headers }
        case .unsupported(let type):
            object["type"] = type
        }
        if let timeout { object["timeout"] = timeout }
        return object
    }

    /// How notes and the list call it: the command's first line, or the URL's host.
    var name: String {
        switch kind {
        case .command(let command):
            let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
            return line.count > 32 ? String(line.prefix(32)) + "…" : line
        case let .http(url, _):
            return URL(string: url)?.host ?? url
        case .unsupported(let type):
            return type
        }
    }

    var isRunnable: Bool {
        if case .unsupported = kind { return false }
        return true
    }
}

struct HookGroup: Equatable, Sendable {
    var matcher: String?
    var handlers: [HookHandler]
    var extra: [String: JSONValue] = [:]
}

/// A hooks.json (H3): `{"hooks": {"PreToolUse": [{"matcher": "write|edit", "hooks": [{"type": "command", …}]}]}}`.
/// Moments Formora doesn't have yet are kept and listed, not run.
struct HookFile: Equatable, Sendable {
    struct Problem: Error, Equatable {
        let message: String
    }

    /// Moment name → groups.
    var events: [String: [HookGroup]] = [:]
    /// Top-level fields besides `hooks`.
    var extra: [String: JSONValue] = [:]

    static func parse(_ data: Data) throws -> HookFile {
        guard !data.isEmpty else { return HookFile() }
        guard let any = try? JSONSerialization.jsonObject(with: data), case .object(var top) = JSONValue(any) else {
            throw Problem(message: "不是合法的 JSON 对象")
        }
        var file = HookFile()
        let hooks = top.removeValue(forKey: "hooks")
        file.extra = top
        guard let hooks else { return file }
        guard case .object(let events) = hooks else { throw Problem(message: "「hooks」应该是一个对象") }
        for (event, value) in events {
            guard case .array(let groups) = value else { throw Problem(message: "「\(event)」应该是一个列表") }
            file.events[event] = try groups.map { group in
                guard case .object(var fields) = group else { throw Problem(message: "「\(event)」里有一项不是对象") }
                let matcher = fields.removeValue(forKey: "matcher")?.string
                guard case .array(let handlers)? = fields.removeValue(forKey: "hooks") else {
                    throw Problem(message: "「\(event)」里有一项缺少 hooks 列表")
                }
                return HookGroup(matcher: matcher, handlers: try handlers.map { handler in
                    guard case .object(let object) = handler else { throw Problem(message: "「\(event)」的 hooks 里有一项不是对象") }
                    return HookHandler(json: object)
                }, extra: fields)
            }
        }
        return file
    }

    func encoded() -> Data {
        var top = extra.mapValues(\.any)
        top["hooks"] = events.mapValues { groups in
            groups.map { group -> [String: Any] in
                var object = group.extra.mapValues(\.any)
                if let matcher = group.matcher, !matcher.isEmpty { object["matcher"] = matcher }
                object["hooks"] = group.handlers.map(\.json)
                return object
            }
        }
        return (try? JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }

    /// One hook as the list shows it, with where it sits in the file.
    struct Entry: Identifiable, Equatable, Sendable {
        let event: String
        let group: Int
        let index: Int
        let matcher: String?
        let handler: HookHandler

        var id: String { "\(event)#\(group)#\(index)" }
        var known: HookEvent? { HookEvent(rawValue: event) }
    }

    /// Every hook, in the order of the moments; moments Formora doesn't know last.
    var entries: [Entry] {
        let order = HookEvent.allCases.map(\.rawValue)
        let names = events.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max, ib = order.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a < b
        }
        return names.flatMap { name in
            (events[name] ?? []).enumerated().flatMap { groupIndex, group in
                group.handlers.enumerated().map { index, handler in
                    Entry(event: name, group: groupIndex, index: index, matcher: group.matcher, handler: handler)
                }
            }
        }
    }

    /// Into the group with the same matcher, or a new one.
    mutating func add(_ handler: HookHandler, event: HookEvent, matcher: String?) {
        let matcher = Self.clean(matcher)
        var groups = events[event.rawValue] ?? []
        if let index = groups.firstIndex(where: { Self.clean($0.matcher) == matcher }) {
            groups[index].handlers.append(handler)
        } else {
            groups.append(HookGroup(matcher: matcher, handlers: [handler]))
        }
        events[event.rawValue] = groups
    }

    mutating func remove(_ entry: Entry) {
        guard var groups = events[entry.event], groups.indices.contains(entry.group),
              groups[entry.group].handlers.indices.contains(entry.index) else { return }
        groups[entry.group].handlers.remove(at: entry.index)
        if groups[entry.group].handlers.isEmpty { groups.remove(at: entry.group) }
        events[entry.event] = groups.isEmpty ? nil : groups
    }

    /// In place while the moment and the matcher stay, so the file keeps its order.
    mutating func replace(_ entry: Entry, with handler: HookHandler, event: HookEvent, matcher: String?) {
        if entry.event == event.rawValue, Self.clean(entry.matcher) == Self.clean(matcher), var groups = events[entry.event],
           groups.indices.contains(entry.group), groups[entry.group].handlers.indices.contains(entry.index) {
            groups[entry.group].handlers[entry.index] = handler
            events[entry.event] = groups
            return
        }
        remove(entry)
        add(handler, event: event, matcher: matcher)
    }

    private static func clean(_ matcher: String?) -> String? {
        let text = matcher?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty || text == "*" ? nil : text
    }
}

/// Claude Code's matcher rule: empty or `*` is every tool; letters, digits and `_ - , |` only is a list of names;
/// anything else is a regular expression, unanchored. Case doesn't matter, so Claude Code's `Write|Edit` fits
/// Formora's `write` and `edit`.
enum HookMatcher {
    static func matches(_ matcher: String?, _ name: String) -> Bool {
        let pattern = (matcher ?? "").trimmingCharacters(in: .whitespaces)
        if pattern.isEmpty || pattern == "*" { return true }
        let plain = pattern.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-,| ".unicodeScalars.contains($0)) }
        if plain {
            return pattern.split(whereSeparator: { $0 == "|" || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .contains(name.lowercased())
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}
