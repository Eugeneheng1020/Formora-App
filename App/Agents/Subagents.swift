import Foundation

/// 子代理 (user 2026-09-15; Claude Code's `.claude/agents/*.md`, omp's bundled agents, Codex's `spawn_agent`): a helper
/// defined by its purpose — a name, a line the Agent picks it by, a system prompt of its own, a tool tier, a model. It
/// has no avatar and no conversation of its own: given work, it runs as a subtask in a blank context and hands back a
/// report. `/agent 目的` creates one; `/名字 任务` sends it work; an Agent delegates to it by name.
struct SubagentDefinition: Equatable, Identifiable, Sendable {
    enum Source: String, Equatable, Sendable {
        /// Shipped with Formora, written into the global folder once so they can be edited or deleted.
        case builtIn
        /// `<project>/.formora/agents/`.
        case project
        /// `<project>/.claude/agents/`, read as they are: what the user wrote for Claude Code works here too.
        case claude
        /// `~/.formora/agents/`.
        case global
    }

    var name: String
    var description: String
    var tier: ToolTier
    /// `nil`: the model of whoever sends the work.
    var model: ModelReference?
    var prompt: String
    var source: Source

    var id: String { name }
    /// `/名字 任务`.
    var command: String { "/" + name }
    /// How the thread and the board name it.
    var displayName: String { "子代理「\(name)」" }
}

/// The file: Claude Code's frontmatter (`name`, `description`, `tools`, `model`) plus Formora's `tier`, the body the
/// system prompt.
enum SubagentFile {
    static func parse(_ text: String, source: SubagentDefinition.Source) -> SubagentDefinition? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---") else { return nil }
        var body = String(rest[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        let fields = header(String(rest[..<end.lowerBound]))
        guard let name = fields["name"].map(singleLine), !name.isEmpty else { return nil }
        let description = fields["description"].map(singleLine) ?? ""
        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let tier = fields["tier"].flatMap(Self.tier) ?? fields["tools"].map(tier(fromTools:)) ?? .exec
        return SubagentDefinition(name: name, description: description, tier: tier, model: model(from: fields["model"]), prompt: prompt,
                                  source: source)
    }

    /// The file text; a round trip through `parse` gives back the same definition. `tools` says the same as `tier` in
    /// Claude Code's words, so its reader gets the intent too.
    static func render(_ definition: SubagentDefinition) -> String {
        var lines = ["---", "name: \(yaml(definition.name))", "description: \(yaml(definition.description))", "tier: \(definition.tier.key)",
                     "tools: \(tools(for: definition.tier))"]
        if let model = definition.model { lines.append("model: \(yaml(model.providerID + "/" + model.modelID))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + definition.prompt + "\n"
    }

    /// `read` / `write` / `exec` (Formora's own key).
    static func tier(_ raw: String) -> ToolTier? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "read", "只读": .read
        case "write", "可写": .write
        case "exec", "all", "全部", "可执行": .exec
        default: nil
        }
    }

    /// Claude Code's `tools: Read, Grep, Bash`: a shell tool makes it exec, a writing tool write, else read.
    static func tier(fromTools list: String) -> ToolTier {
        let names = Set(list.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.lowercased() })
        if names.contains(where: { ["bash", "shell", "execute", "computer"].contains($0) }) { return .exec }
        if names.contains(where: { ["write", "edit", "multiedit", "notebookedit", "write_file", "edit_file"].contains($0) }) { return .write }
        return .read
    }

    static func tools(for tier: ToolTier) -> String {
        switch tier {
        case .read: "Read, Grep, Glob, WebFetch"
        case .write: "Read, Grep, Glob, WebFetch, Write, Edit"
        case .exec: "Read, Grep, Glob, WebFetch, Write, Edit, Bash"
        }
    }

    /// `provider/model` pins a model; Claude Code's `sonnet` / `inherit` and the like mean whoever calls.
    static func model(from raw: String?) -> ModelReference? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), let slash = raw.firstIndex(of: "/") else { return nil }
        let provider = String(raw[..<slash]), model = String(raw[raw.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return ModelReference(providerID: provider, modelID: model)
    }

    // The header reader, as SkillDocument has it.
    private static func header(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fields: [String: String] = [:]
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "#", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            var continued: [String] = []
            while index < lines.count, lines[index].first?.isWhitespace ?? true {
                continued.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            if fields[key] == nil { fields[key] = scalar(value, continued) }
        }
        return fields
    }

    private static func scalar(_ value: String, _ continued: [String]) -> String {
        if value.first == "|" || value.first == ">" { return continued.joined(separator: "\n") }
        let joined = ([value] + continued).filter { !$0.isEmpty }.joined(separator: " ")
        if value.first == "\"" || value.first == "'" {
            var text = joined
            if text.count >= 2, text.first == text.last { text = String(text.dropFirst().dropLast()) }
            return text.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return joined.range(of: " #").map { String(joined[..<$0.lowerBound]) } ?? joined
    }

    private static func singleLine(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private static func yaml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension ToolTier {
    var key: String {
        switch self {
        case .read: "read"
        case .write: "write"
        case .exec: "exec"
        }
    }

    var label: String {
        switch self {
        case .read: "只读"
        case .write: "可写"
        case .exec: "可执行命令"
        }
    }
}

/// A subagent's name is also its command, so it can't be one Formora already has (user 2026-09-15).
enum SubagentNames {
    static let lengthLimit = 32
    /// Never a subagent's: the composer's commands, `/agent` itself, the Skill prefix, and the clone words.
    static let reserved: Set<String> = ["agent", "agents", "skill", "分身", "自己", "clone", "self", "bob"]

    static func normalize(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Why a name can't be used, in the user's words; `nil` when it can.
    static func problem(with raw: String, commands: [String]) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "起个名字" }
        guard name.count >= 2 else { return "名字至少 2 个字" }
        guard name.count <= lengthLimit else { return "名字最多 \(lengthLimit) 个字" }
        guard name.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "_" }) else {
            return "名字只能用中文、字母、数字、- 和 _，不能有空格和斜杠"
        }
        let key = normalize(name)
        let taken = Set(commands.map { normalize($0.hasPrefix("/") ? String($0.dropFirst()) : $0) }).union(reserved)
        guard !taken.contains(key) else { return "「\(name)」和现有指令重名，换一个" }
        return nil
    }

    /// A new one's name (user 2026-09-17): English — lower-case letters, digits, hyphens, a letter first — so `/name`
    /// is typed without switching the input method. The description says what it is, in Chinese. Files named
    /// otherwise — the user's earlier ones, Claude Code's — still load: `problem(with:)` is all they must pass.
    static func creationProblem(with raw: String, commands: [String]) -> String? {
        if let problem = problem(with: raw, commands: commands) { return problem }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EnglishSlug.isValid(name) else {
            return "名字用英文：小写字母、数字和 -，字母开头，比如 code-reviewer；它是干什么的写在简介里"
        }
        return nil
    }

    /// What a model's or a user's try at a name comes to under that rule; empty when nothing of it is English.
    static func slug(_ raw: String) -> String { EnglishSlug.make(raw, limit: lengthLimit) }
}

/// Everything that turns a purpose into a definition (user 2026-09-15: 依据目的创建它的 system prompt).
enum SubagentGenerator {
    struct Draft: Equatable, Sendable {
        var name: String
        var description: String
        var tier: ToolTier
        var prompt: String
    }

    /// 起草用的系统提示词就是那份隐藏的撰写指南（user 2026-09-16），用户不必再逐字看提示词。
    static var system: String { SubagentAuthoring.guide }

    /// `problem`: what was wrong with the first try, when it is asked again (user 2026-09-17: nobody is shown a form).
    static func request(purpose: String, reserved: [String], problem: String? = nil) -> String {
        "目的：\n\(purpose)\n\nreserved（不能用的名字）：\(reserved.joined(separator: "、"))"
            + (problem.map { "\n\n上一次你写的不能用：\($0)。这次改掉，其余照旧，仍然只输出 JSON。" } ?? "")
    }

    /// The name a draft is saved under, settled without asking (user 2026-09-17): English as given, folded into
    /// lower-case and hyphens when it isn't, numbered when a command or another subagent has it. `nil` when there is
    /// nothing English in it to fold — then the model is asked again.
    static func settledName(_ raw: String, taken: [String], commands: [String]) -> String? {
        let given = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = EnglishSlug.isValid(given) ? given : SubagentNames.slug(given)
        guard base.count >= 2 else { return nil }
        let used = Set(taken.map(SubagentNames.normalize))
        var candidate = base
        var number = 2
        while used.contains(candidate) || SubagentNames.creationProblem(with: candidate, commands: commands) != nil {
            candidate = "\(base.prefix(SubagentNames.lengthLimit - 3))-\(number)"
            number += 1
            if number > 99 { return nil }
        }
        return candidate
    }

    /// The thread's line once it is made (user 2026-09-17): in 消息 and, the board reading the same thread, in the
    /// canvas's window — its name and command, what it is for, its tools, where it is kept.
    static func created(_ definition: SubagentDefinition) -> ThreadEvent {
        let place = definition.source == .project ? "存在本项目" : "存在全局"
        var event = ThreadEvent(kind: .subagent, title: "已创建子代理 \(definition.name)",
                                detail: [definition.description, "/\(definition.name) 任务 派活 · \(AppState.tierLabel(definition.tier)) · \(place)"]
                                    .filter { !$0.isEmpty }.joined(separator: "\n"))
        event.passed = true
        return event
    }

    static func failed(_ reason: String) -> ThreadEvent {
        var event = ThreadEvent(kind: .subagent, title: "子代理没创建成功", detail: reason)
        event.passed = false
        return event
    }

    /// The JSON in the reply — fenced or bare; `nil` when it can't be read.
    static func parse(_ reply: String) -> Draft? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String { (object[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = text("name"), description = text("description"), prompt = text("prompt")
        guard !name.isEmpty, !prompt.isEmpty else { return nil }
        return Draft(name: name, description: description, tier: SubagentFile.tier(text("tools")) ?? .read, prompt: prompt)
    }
}
