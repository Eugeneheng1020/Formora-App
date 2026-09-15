import Foundation

/// Agents working together (7g): the limits, named once — the tools' descriptions, the refusals and the banners
/// read them from here.
enum TeamLimits {
    /// A chain of hand-offs from one user message (M3).
    static let hops = 6
    static let chainTokens = 500_000
    /// One subtask (S4).
    static let subtaskCalls = 30
    static let subtaskDeadline: TimeInterval = 10 * 60
    static let subtaskTokens = 200_000
    /// One run's delegations (S3, S4).
    static let delegationsPerRun = 8
    static let concurrentSubtasks = 4
    static let delegatedTokensPerRun = 1_000_000
    /// What comes back of a subtask's report (S5).
    static let reportCharacters = 6_000
    /// Failed work taken over, per user message (9e, E): twice at most — a host down for everyone would go round.
    static let takeovers = 2
    /// Autorun (A1).
    static let rounds = 10
    static let goalTokens = 500_000
}

/// What Agents hand each other (7g): the work (M2), a subtask (S1), a goal met (A3). Descriptions are for the model,
/// never shown.
enum TeamTools {
    static let handoff = ToolSpec(
        name: "handoff",
        description: "Hand the rest of this task to another member of the group chat when the next part is their role's work (the PRD is done and development starts; the code is written and needs testing). Your reply so far stays in the thread; after this call your turn ends and they take over at once. Write the brief for them: what is done, where it is (file paths), what they should do next, what is still open. Not for questions (ask the user), not to yourself. At most \(TeamLimits.hops) hand-offs follow one user message.",
        parameters: #"{"type":"object","properties":{"to":{"type":"string","description":"The member's name as the group lists it, e.g. 研发（前端）; a role's name (研发) lets its idle member take it"},"brief":{"type":"string","description":"What they need to know and do next"}},"required":["to","brief"]}"#,
        tier: .read)

    static let delegateName = "delegate"

    /// The colleagues are named in the description: who may be asked, besides the Agent's own clone — and the subagents
    /// (user 2026-09-15), each with the line that says when to pick it.
    static func delegate(colleagues: [String], subagents: [(name: String, description: String)] = []) -> ToolSpec {
        var who = colleagues.isEmpty
            ? "No colleague can take work right now: only your clone."
            : "Colleagues you can delegate to: " + colleagues.joined(separator: "; ") + "."
        if !subagents.isEmpty {
            who += " Subagents — purpose-built helpers with their own instructions; pick one by its line and put its name in `to`: "
                + subagents.map { "\($0.name)（\($0.description)）" }.joined(separator: "; ") + "."
        }
        return ToolSpec(
            name: delegateName,
            description: "Delegate a well-bounded piece of work: to a colleague (another Agent of this project), or — without `to` — to your own clone (your role, model and tools, but a blank context). The helper works from scratch in a separate subtask the user can open; its final report comes back as this call's result, then you carry on. Good for: research that splits into parts to run in parallel, exploration that would flood your context with material, another role's expertise. Not for: a step or two you can do yourself, anything that needs back-and-forth with the user. The helper knows nothing of this conversation: make `task` self-contained — goal, scope and non-goals, acceptance criteria — put what you already know in `context`, and list the project files it should read first in `files`. Several delegate calls in one reply run at the same time. At most \(TeamLimits.delegationsPerRun) per run. " + who,
            parameters: #"{"type":"object","properties":{"to":{"type":"string","description":"A colleague's name as listed, or a subagent's name; omit it (or write 分身) for your own clone"},"task":{"type":"string","description":"Self-contained: the goal, scope and non-goals, acceptance criteria"},"context":{"type":"string","description":"What you already know: decisions, constraints, interfaces with other subtasks"},"files":{"type":"array","items":{"type":"string"},"description":"Project files the helper reads first, relative paths"},"read_only":{"type":"boolean","description":"Look, don't change: the helper only gets the reading tools"},"expect":{"type":"string","description":"The report you want back, e.g. a table: option / evidence / risk"}},"required":["task"]}"#,
            tier: .write)
    }

    static let goalDone = ToolSpec(
        name: "goal_done",
        description: "Say the goal is met. Only when every deliverable of the objective has direct evidence in the project's current state — files you read, command output — not from memory; uncertain means not met, keep working. Another Agent then checks it; your turn ends with this call. Running out of budget is not completion.",
        parameters: #"{"type":"object","properties":{"evidence":{"type":"string","description":"Each deliverable, what satisfies it and how you checked"}},"required":["evidence"]}"#,
        tier: .read)

    /// Every tool here, for the tier and plan mode (the roster in delegate's description doesn't change either).
    static let all = [handoff, delegate(colleagues: []), goalDone]

    static func handoffArguments(_ json: String) -> (to: String, brief: String)? {
        guard let args = ToolArguments.parse(json) else { return nil }
        let to = (args["to"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = (args["brief"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, !brief.isEmpty else { return nil }
        return (to, brief)
    }

    /// M2: a reply whose last non-empty line starts with `@` and a name hands the work on; the rest of that line is
    /// the brief. A name anywhere else is only a mention. Longer names are tried first (like the `@` of 6c).
    static func trailingHandoff(in text: String, names: [String]) -> (name: String, brief: String)? {
        guard let line = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { !$0.isEmpty }),
              let first = line.first, first == "@" || first == "＠" else { return nil }
        let rest = String(line.dropFirst())
        for name in names.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            guard let range = rest.range(of: name, options: [.anchored, .caseInsensitive, .widthInsensitive]) else { continue }
            let brief = rest[range.upperBound...].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "：:，,")))
            return (name, brief)
        }
        return nil
    }

    /// Whom a name means: a member's full or own name; else a role's, answered by whichever of that role is idle
    /// (the first of them when none is).
    @MainActor
    static func resolve(_ raw: String, among agents: [AgentRecord], isIdle: (UUID) -> Bool) -> AgentRecord? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") || name.hasPrefix("＠") { name.removeFirst() }
        let key = FileSearch.normalize(name)
        guard !key.isEmpty else { return nil }
        if let agent = agents.first(where: { FileSearch.normalize($0.displayName) == key || FileSearch.normalize($0.customName) == key }) {
            return agent
        }
        let ofRole = agents.filter { FileSearch.normalize($0.role.name) == key }
        return ofRole.first { isIdle($0.id) } ?? ofRole.first
    }
}

/// One delegate call's arguments (S1).
struct Delegation: Equatable, Sendable {
    /// `nil`: the Agent's own clone.
    var to: String?
    var task: String
    var context = ""
    var files: [String] = []
    var readOnly = false
    var expect = ""

    static let cloneNames: Set<String> = ["分身", "自己", "clone", "self"]

    static func parse(_ json: String) -> Delegation? {
        guard let args = ToolArguments.parse(json) else { return nil }
        func text(_ key: String) -> String { (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let task = text("task")
        guard !task.isEmpty else { return nil }
        let to = text("to")
        let files = ((args["files"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Delegation(to: to.isEmpty || cloneNames.contains(to.lowercased()) ? nil : to, task: task, context: text("context"),
                          files: files, readOnly: args["read_only"] as? Bool ?? false, expect: text("expect"))
    }

    /// The subtask's name: the task's first line, like a task name (≤ 20 characters).
    var title: String {
        let line = task.split(whereSeparator: \.isNewline).first.map(String.init) ?? task
        return line.count > 20 ? String(line.prefix(20)) + "…" : line
    }

    /// The subtask's first message: all the helper knows.
    func brief(from requester: String) -> String {
        var parts = ["〔\(requester) 委派给你的子任务〕", "任务：\n\(task)"]
        if !context.isEmpty { parts.append("背景：\n\(context)") }
        if !expect.isEmpty { parts.append("交回的报告：\(expect)") }
        if readOnly { parts.append("这件事只查不改：你只有读取类的工具。") }
        return parts.joined(separator: "\n\n")
    }
}

/// M1: who takes a group message that `@`-s nobody.
enum Dispatcher {
    static let system = """
    你是群聊的调度员。用户发了一条没有 @ 任何人的消息，你决定交给哪一个成员。
    规则：按任务的性质选岗位；同一个岗位有几个人时，选空闲的；这条消息是接着之前某人做的活，就交给那个人。
    只回一行 JSON，不要别的：{"to": "成员的名字", "reason": "一句话理由"}
    """

    struct Member: Equatable {
        let name: String
        let role: String
        let subtitle: String
        let isBusy: Bool
    }

    static func request(message: String, members: [Member], recent: [(speaker: String, text: String)]) -> String {
        var lines = ["成员："]
        for member in members {
            lines.append("- \(member.name)：\(member.role)" + (member.subtitle.isEmpty ? "" : "，\(member.subtitle)")
                         + (member.isBusy ? "（正在别的对话里忙）" : "（空闲）"))
        }
        if !recent.isEmpty {
            lines.append("\n最近的对话：")
            for line in recent { lines.append("〔\(line.speaker)〕\(line.text)") }
        }
        lines.append("\n用户的新消息：\n\(message)")
        return lines.joined(separator: "\n")
    }

    /// The JSON object, even inside a code fence or with words around it.
    static func parse(_ reply: String) -> (to: String, reason: String)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let to = (object["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else { return nil }
        return (to, (object["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// `/loop` and `/goal` (A1, A3).
enum Autoruns {
    /// `/loop N [要做的事]`: the number first, in ASCII digits.
    static func parseLoop(_ argument: String) -> (rounds: Int, text: String)? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard let rounds = Int(digits), rounds > 0 else { return nil }
        return (rounds, trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What a round's model reads first (A2); the objective itself is in the prompt (A3).
    static func instruction(round: Int, of total: Int, loopText: String?, objective: String?) -> String {
        if let objective {
            if round == 1 { return "（目标模式 · 第 1 轮）朝这个目标做：\n\(objective)" }
            return "（目标模式 · 第 \(round) 轮）继续朝目标做。不要把成功偷换成更小、更容易或已经做完的一部分；调用 goal_done 之前，对照每一项交付物查看项目现在的样子。"
        }
        let text = loopText ?? ""
        if round == 1 { return "（自主运行 · 第 1/\(total) 轮）" + (text.isEmpty ? "接着上一轮往下做。" : text) }
        return "（自主运行 · 第 \(round)/\(total) 轮）接着上一轮往下做" + (text.isEmpty ? "。" : "：\(text)")
    }

    /// The check's brief (A3): read-only, the verdict on the first line.
    static func checkBrief(objective: String, evidence: String, executor: String) -> String {
        """
        复核一个目标是否已经达成。只看项目现在的样子（读文件、查内容），不改任何东西。

        目标：
        \(objective)

        \(executor) 说已经达成，给的依据：
        \(evidence)

        逐项对照目标的每一项交付物找直接证据；证据不足就算未达成。报告第一行只写「达成」或「未达成」，后面写理由；未达成时写清还差什么。
        """
    }

    /// The check's first line: `true` met, `false` not; anything else counts as not met.
    static func verdict(_ report: String) -> Bool {
        let first = report.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        if first.contains("未达成") || first.contains("没有达成") { return false }
        return first.contains("达成")
    }
}
