import Foundation

/// 要你做决定的事一律停在输入框上方 (user 2026-09-15; spec §5): 等你确认, 选项确认, a reply's numbered ways, 方案出来了,
/// 要继续吗, 重试 — cards and the board's 「运行过程」 only tell, the composer's dock asks. Pure lookups; the composer reads them.
enum Decisions {
    /// A tool call waiting for 允许 / 拒绝, wherever it runs.
    struct PendingApproval: Equatable {
        /// The conversation whose runner waits: the conversation itself, or a subtask's.
        let runID: UUID
        let messageID: UUID
        let call: ToolCall
        let approval: ChatRunner.Approval
        /// Set when a helper's step waits — the panel names the helper.
        let subtaskID: UUID?
    }

    /// The board's focused run first (a delegation's card runs in its subtask), then the conversation's own, then any
    /// helper's — a step waiting in a lane is decided above the parent's composer (S6).
    static func approval(for conversation: Conversation, focus: UUID?, subtasks: [Conversation],
                         approvals: [UUID: ChatRunner.Approval]) -> PendingApproval? {
        var candidates: [Conversation] = []
        if let focus {
            if focus == conversation.id { candidates.append(conversation) } else if let subtask = subtasks.first(where: { $0.id == focus }) {
                candidates.append(subtask)
            }
        }
        candidates.append(conversation)
        candidates.append(contentsOf: subtasks)
        for candidate in candidates {
            guard let approval = approvals[candidate.id],
                  let call = candidate.messages.first(where: { $0.id == approval.messageID })?.toolCalls.first(where: { $0.id == approval.callID })
            else { continue }
            return PendingApproval(runID: candidate.id, messageID: approval.messageID, call: call, approval: approval,
                                   subtaskID: candidate.id == conversation.id ? nil : candidate.id)
        }
        return nil
    }

    /// The last reply that is shown — the loop's own nudges never are.
    private static func lastShown(_ conversation: Conversation) -> Message? {
        conversation.messages.last { !$0.isHidden }
    }

    /// A plan-mode run ended on its answer (D5): 「按这个计划做」 waits.
    static func planAwaitsApproval(_ conversation: Conversation, isRunning: Bool, hasQuestion: Bool) -> Bool {
        guard conversation.planMode, !isRunning, !hasQuestion, let last = lastShown(conversation) else { return false }
        return last.role == .agent && last.failure == nil && last.pause == nil
    }

    /// The run stopped to ask 「继续？」 (L2), and why.
    static func pause(_ conversation: Conversation, isRunning: Bool) -> String? {
        guard !isRunning, let last = lastShown(conversation), last.role == .agent else { return nil }
        return last.pause
    }

    /// The last reply never came (L3), and why: 重试 waits.
    static func failure(_ conversation: Conversation, isRunning: Bool) -> String? {
        guard !isRunning, let last = lastShown(conversation), last.role == .agent else { return nil }
        return last.failure
    }

    /// The last reply lists ways and asks which: a card, unless another decision waits or the user put this one away.
    static func choices(_ conversation: Conversation, isRunning: Bool, hasQuestion: Bool, hasApproval: Bool,
                        dismissed: Set<UUID>) -> (messageID: UUID, found: ProseChoices.Found)? {
        guard !isRunning, !hasQuestion, !hasApproval, let last = lastShown(conversation), last.role == .agent,
              last.failure == nil, last.pause == nil, !dismissed.contains(last.id), let found = ProseChoices.find(in: last.text) else { return nil }
        return (last.id, found)
    }
}

/// What a waiting step says it will do, and the command as it will run — the words of the approval panel (D34, D79).
enum ApprovalText {
    static func what(_ call: ToolCall, reason: String?) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        if let reason {
            return call.name == "bash" ? "这条命令\(reason)。不管权限模式怎么设，这类命令都先问你。" : "\(reason)。不管权限模式怎么设，这一步都先问你。"
        }
        if call.name == ComputerTool.name {
            return "要操作电脑，做下面这几步。允许后，这次任务里它再操作电脑就不再问你；屏幕顶部会出现停止条，按 ⌘ + Esc 或者在别的应用里动一下鼠标键盘就会停。"
        }
        if call.name == ScriptTools.osascript.name {
            return "要运行这段脚本，它可能会控制别的应用（macOS 会为每个被控制的应用单独问你一次）。按这个 Agent 的「权限模式」，需要你确认。"
        }
        if call.name == ScriptTools.shortcutRun.name {
            return "要运行你的快捷指令「\(args["name"] as? String ?? "")」。按这个 Agent 的「权限模式」，需要你确认。"
        }
        if call.name == "bash" { return "要在项目文件夹里运行这条命令。按这个 Agent 的「权限模式」，需要你确认。" }
        if call.name == "open_url" { return "要在你的浏览器里打开 \(args["url"] as? String ?? "这个网址")。按这个 Agent 的「权限模式」，需要你确认。" }
        let path = args["path"] as? String ?? "文件"
        let what: String
        switch call.name {
        case "write":
            let count = (args["content"] as? String)?.count ?? 0
            what = "要把 \(count) 个字写进 \(path)"
        case "edit":
            let old = ((args["old_text"] as? String) ?? "").prefix(24)
            what = "要改 \(path) 里的「\(old)\(old.count == 24 ? "…" : "")」"
        default:
            what = "要\(call.summary)"
        }
        return "\(what)。按这个 Agent 的「权限模式」，这一步需要你确认。"
    }

    /// What is being allowed, in full: a command as it will run, a script, or a computer call's steps (7j, C2).
    static func command(_ call: ToolCall) -> String? {
        if call.name == "mcp_add" { return MCPConnect.commandLine(call.arguments) }
        if call.name == ComputerTool.name { return ComputerTool.steps(call.arguments) }
        if call.name == ScriptTools.osascript.name {
            return (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any])?["script"] as? String
        }
        guard call.name == "bash" else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any])?["command"] as? String
    }
}

/// 选项确认的几个问题 (user 2026-09-15): forward as they are answered, 上一步 to see and change an earlier answer, back to
/// the question in hand after a change.
struct AskNavigation: Equatable {
    let count: Int
    private(set) var answered: [AskTool.Answer]
    /// An earlier question being shown again; `nil` = the one in hand.
    private(set) var viewing: Int?

    init(count: Int, answered: [AskTool.Answer] = [], viewing: Int? = nil) {
        self.count = max(count, 1)
        self.answered = Array(answered.prefix(self.count))
        self.viewing = viewing.flatMap { $0 < self.answered.count ? $0 : nil }
    }

    /// The question shown.
    var index: Int { viewing ?? min(answered.count, count - 1) }
    var canGoBack: Bool { index > 0 }
    /// Shown an earlier question: the way forward without changing it.
    var canGoForward: Bool { viewing != nil }
    /// What the shown question was answered with, if it was.
    var picked: [String] { index < answered.count ? answered[index].picked : [] }

    mutating func back() {
        guard canGoBack else { return }
        viewing = index - 1
    }

    mutating func forward() {
        guard let shown = viewing else { return }
        viewing = shown + 1 < answered.count ? shown + 1 : nil
    }

    /// Records the shown question's answer — replacing an earlier one — and returns whether every question is answered.
    mutating func record(_ answer: AskTool.Answer) -> Bool {
        let at = index
        viewing = nil
        if at < answered.count {
            answered[at] = answer
            return false
        }
        answered.append(answer)
        return answered.count >= count
    }
}
