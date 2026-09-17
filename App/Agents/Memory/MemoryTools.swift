import Foundation

/// One write to the memory, as the thread's line keeps it: what 撤销 needs to put things back (user 2026-09-17).
struct MemoryChange: Codable, Equatable, Sendable {
    enum Op: String, Codable, Sendable { case add, update, forget }

    var op: Op
    var scope: MemoryScope
    var before: MemoryEntry?
    var after: MemoryEntry?

    /// 「记下了（全局）：……」
    var line: String {
        let summary = (after ?? before)?.summary ?? ""
        return switch op {
        case .add: "记下了（\(scope.label)）：\(summary)"
        case .update: "更新了记忆（\(scope.label)）：\(summary)"
        case .forget: "忘掉了（\(scope.label)）：\(summary)"
        }
    }
}

/// `remember` and `recall` (user 2026-09-17; before: a note or a whole rewrite, and an extraction after every run).
/// What may be remembered is checked here, not left to the model: a note needs the user's own words for it (omp's
/// evidence rule: an exact piece of what the human wrote), or — a lesson — a failure in the conversation.
enum MemoryTools {
    /// Who is writing: the layers it reads and writes, what the user said in this conversation, whether a call failed.
    struct Context {
        var readable: [MemoryScope]
        /// By the name the tool takes: global, project, agent — Bob: global, bob.
        var writable: [String: MemoryScope]
        var userWords: [String]
        var hasFailure: Bool
        var source: UUID?
    }

    /// Fewer characters than this isn't a quote, it is a word.
    static let evidenceMinimum = 4

    /// What an Agent's `remember` says of the layers, and Bob's.
    static let agentScopes = "global (true in every project: who the user is, how to work with them, red lines) | project (its decisions, conventions, lessons — shared by its Agents) | agent (what the user wants from your role)"
    static let bobScopes = "global (about the user, true everywhere) | bob (what the user asks of you, your lessons running Formora — never a project's facts)"

    /// 2026-09-18: said once, and briefly — this was the longest tool there is, and the prompt said it all again.
    static func rememberSpec(scopes: String, names: String) -> ToolSpec {
        ToolSpec(
            name: "remember",
            description: "Keep one note for later conversations — rarely: only when the user told you to remember it, corrected you, or settled a choice (kind profile | preference | decision), or something failed first and you then found what works (kind lesson — a project's). Only what changes what you do next time, outlives this task and isn't in the files; never progress, your unadopted suggestions, guesses or changing numbers. op add: scope — \\(scopes); kind; summary (one self-contained sentence, always in sight); body (optional: the reason); evidence — the user's exact words from this conversation (an option-card pick counts; quote a one-word go-ahead whole), or for a lesson what failed and what fixed it; what they did not say is refused. op update: id, new summary and/or body, evidence. op forget: id — when the user asks, or a note is wrong.",
            parameters: #"{"type":"object","properties":{"op":{"type":"string","enum":["add","update","forget"]},"scope":{"type":"string","description":"For add: \#(names)"},"kind":{"type":"string","enum":["profile","preference","decision","lesson"]},"summary":{"type":"string"},"body":{"type":"string"},"evidence":{"type":"string","description":"The user's exact words"},"id":{"type":"string","description":"For update and forget: like p4"}},"required":["op"]}"#,
            tier: .read)
    }

    static let remember = rememberSpec(scopes: agentScopes, names: "global | project | agent")

    static let recall = ToolSpec(
        name: "recall",
        description: "Read the full text of notes from your memory directory — the ones marked （有正文） that bear on what you are doing now. Pass their numbers.",
        parameters: #"{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"},"description":"Numbers from the directory, like [\"p4\",\"g1\"]"}},"required":["ids"]}"#,
        tier: .read)

    /// The prompt's rule wherever `remember` is offered (2026-09-18: a sentence — the tool's own words carry the rest,
    /// and what may be kept is the program's to check, not the prompt's to repeat).
    static let promptRule = "记忆要少而准：只有用户让你记住、纠正了你、拍了板，或一件事先失败后解决时，才用 remember 记一条，evidence 逐字引用用户的话；用户让你忘掉什么用 forget。"

    /// The bar in full, for the look back over a quiet conversation (`MemoryUpkeep`), which has no tool to read it from.
    static let rules = "记忆要少而准。只在四种时候用 remember 记一条：用户明确要你记住；用户纠正了你；用户在几个方案里拍了板；一件事先失败、后来你找到了正确做法。三条都满足才记：下次会改变你的默认做法；不是只对这一次有用；项目文件里、对话里查不到。不记：任务进度、这次改了什么、你自己提的而用户没采纳的方案、猜测、会变的数值。放哪一层：任何项目都适用的（用户是谁、怎么沟通、红线）放 global；这个项目的决定、约定和踩过的坑放 project；用户对你这个岗位产出的要求放 agent。evidence 要逐字引用用户说过的话（或他在选项卡片上选的那一项），用户没说过的不记；他只回了「B」「好」这样一个词来拍板，就引用那整条回复。用户让你忘掉什么，用 forget。"

    // MARK: remember

    @MainActor
    static func remember(_ json: String, store: MemoryStore, context: Context, now: Date = .now) -> (result: ToolResult, change: MemoryChange?) {
        guard let args = ToolArguments.parse(json) else { return (.failed("参数不是合法的 JSON 对象"), nil) }
        let string = { (key: String) in (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch string("op") ?? (string("id") == nil ? "add" : "update") {
        case "add":
            guard let name = string("scope"), let scope = context.writable[name.lowercased()] else {
                return (.failed("scope 只能是：" + context.writable.keys.sorted().joined(separator: "、") + "。没有记。"), nil)
            }
            let kind = string("kind").flatMap(MemoryEntry.Kind.init(rawValue:)) ?? .preference
            if let refusal = refusal(kind: kind, evidence: string("evidence") ?? "", context: context) { return (.failed(refusal), nil) }
            switch store.add(kind: kind, summary: string("summary") ?? "", body: string("body") ?? "", to: scope, source: context.source, now: now) {
            case .success(let added) where added.confirmed:
                return (.done("已经记过（\(added.entry.id)），日期更新成今天了。"), nil)
            case .success(let added):
                let change = MemoryChange(op: .add, scope: scope, before: nil, after: added.entry)
                return (.done("\(change.line)。编号 \(added.entry.id)。"), change)
            case .failure(let problem):
                return (.failed(problem.message + "。没有记。"), nil)
            }
        case "update":
            guard let found = string("id").flatMap({ store.find($0, in: Array(context.writable.values)) }) else {
                return (.failed(unknown(string("id") ?? "", store: store, context: context)), nil)
            }
            if let refusal = refusal(kind: found.entry.kind, evidence: string("evidence") ?? "", context: context) { return (.failed(refusal), nil) }
            switch store.update(found.entry.id, in: found.scope, summary: string("summary"), body: args["body"] as? String, now: now) {
            case .success(let changed):
                let change = MemoryChange(op: .update, scope: found.scope, before: changed.before, after: changed.after)
                return (.done(change.line + "。"), change)
            case .failure(let problem):
                return (.failed(problem.message + "。没有改。"), nil)
            }
        case "forget":
            guard let found = string("id").flatMap({ store.find($0, in: Array(context.writable.values)) }),
                  case .success(let gone) = store.forget(found.entry.id, in: found.scope) else {
                return (.failed(unknown(string("id") ?? "", store: store, context: context)), nil)
            }
            let change = MemoryChange(op: .forget, scope: found.scope, before: gone, after: nil)
            return (.done(change.line + "。用户可以在对话里撤销。"), change)
        default:
            return (.failed("op 只能是 add、update、forget"), nil)
        }
    }

    /// Why this may not be remembered, or `nil`. What the user said is looked for as it was written: whitespace
    /// aside, full-width and half-width punctuation alike — a model rarely copies those two faithfully.
    static func refusal(kind: MemoryEntry.Kind, evidence: String, context: Context) -> String? {
        if kind == .lesson {
            return context.hasFailure ? nil : "经验（lesson）只记先失败、后解决的事；这个对话里没有失败过的步骤，一次做成的不记。没有记。"
        }
        let quote = folded(evidence)
        // A choice is often settled in a word — 「B」, 「好」, a pick on an option card: for a decision, a quote that is
        // the user's whole message counts, however short (omp: short replies are decisions too, resolved from context).
        if kind == .decision, !quote.isEmpty, context.userWords.contains(where: { folded($0) == quote }) { return nil }
        guard quote.count >= evidenceMinimum, context.userWords.contains(where: { folded($0).contains(quote) }) else {
            return "evidence 要逐字引用用户在这个对话里说过的话（至少 \(evidenceMinimum) 个字）；用户没说过的不记——你自己的判断、提议和总结都不算。没有记。"
        }
        return nil
    }

    private static let punctuation: [Character: Character] = ["，": ",", "。": ".", "：": ":", "；": ";", "！": "!", "？": "?", "（": "(", "）": ")",
                                                              "“": "\"", "”": "\"", "‘": "'", "’": "'"]

    static func folded(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace }.map { punctuation[$0] ?? $0 })
    }

    @MainActor
    private static func unknown(_ id: String, store: MemoryStore, context: Context) -> String {
        let known = context.writable.values.flatMap { store.entries($0).map(\.id) }.sorted()
        return "没有编号为 \(id) 的记忆。" + (known.isEmpty ? "现在还没有记忆。" : "有的：" + known.joined(separator: "、"))
    }

    // MARK: recall

    @MainActor
    static func recall(_ json: String, store: MemoryStore, context: Context, now: Date = .now) -> ToolResult {
        guard let args = ToolArguments.parse(json) else { return .failed("参数不是合法的 JSON 对象") }
        let ids = ((args["ids"] as? [Any]) ?? (args["id"].map { [$0] } ?? [])).compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return .failed("缺少参数 ids：目录里的编号，比如 [\"p4\"]") }
        var parts: [String] = []
        for id in ids {
            guard let found = store.find(id, in: context.readable) else {
                parts.append("没有 \(id) 这条记忆。")
                continue
            }
            store.touch([found.entry.id], in: found.scope, now: now)
            let entry = found.entry
            parts.append("[\(found.scope.directoryLabel)] \(entry.id) \(entry.summary)（\(entry.created) 记下）"
                         + (entry.hasBody ? "\n" + entry.body : "\n（没有正文，就这一句）"))
        }
        return .done(parts.joined(separator: "\n\n") + "\n\n记忆可能已经过时：和用户现在说的或项目现状冲突时，以现在为准。")
    }

    // MARK: 撤销

    @MainActor
    static func undo(_ change: MemoryChange, store: MemoryStore) {
        switch change.op {
        case .add:
            if let after = change.after { _ = store.forget(after.id, in: change.scope) }
        case .update, .forget:
            if let before = change.before { store.restore(before, in: change.scope) }
        }
    }
}
