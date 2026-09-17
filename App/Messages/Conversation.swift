import Foundation

/// One conversation: a direct chat with one Agent or a group of Agents, inside one project (spec §9).
/// A value type so a snapshot can go to the background writer as it is.
struct Conversation: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case direct, group
    }

    var id: UUID
    var kind: Kind
    var projectID: UUID
    /// Direct chats only. Kept after the Agent is deleted, so the chat can say so (C17).
    var agentID: UUID?
    /// Group chats only: the stable name the list and the board find it by (spec §9.10).
    var groupName: String
    var members: [GroupMember]
    /// The task name in the header and the row's badge (spec §9.4).
    var title: String
    /// `false` once the user renamed it: automatic naming never overwrites a manual name.
    var titleIsAuto: Bool
    /// The model has named the task (7a); until then the name is the first sentence.
    var titleIsModelNamed = false
    var status: ConversationStatus
    var visibility: ConversationVisibility
    var reasoning: ReasoningLevel
    var unread: Int
    var createdAt: Date
    /// Last activity; orders the list and dates the row.
    var updatedAt: Date
    var messages: [Message]
    /// The Agent's plan for the task (7d, D4), shown docked above the composer while steps are open.
    var plan: [PlanItem] = []
    /// `/plan` (D5): look, ask and plan; change nothing until the user says go.
    var planMode = false
    /// When it was last looked over for what the memory missed (user 2026-09-17): at most once a day.
    var memoryPassAt: Date?
    /// A subtask's place (7g, S2): kept out of the list, opened from its parent's card.
    var parent: SubtaskLink?
    /// The board (8a, K3): the user's card positions and auto / custom — the one thing about the canvas that can't be derived.
    var boardLayout: BoardLayout?
    /// A group named for its task when a direct chat became one (8d, K14): it follows the task's name until the user
    /// names the group (9e, H).
    var groupNameIsAuto = false
    /// Card titles Bob gave (9e, H): by card id, or by the message whose cards they are.
    var cardTitles: [String: String] = [:]
    /// What edited messages replaced (10e), oldest first — each under its line in the thread.
    var earlier: [EarlierVersion] = []

    init(id: UUID = UUID(), kind: Kind, projectID: UUID, agentID: UUID? = nil, groupName: String = "",
         members: [GroupMember] = [], title: String, titleIsAuto: Bool = true, status: ConversationStatus = .pending,
         visibility: ConversationVisibility = .normal, reasoning: ReasoningLevel = .auto, unread: Int = 0,
         createdAt: Date = .now, updatedAt: Date? = nil, messages: [Message] = []) {
        self.id = id
        self.kind = kind
        self.projectID = projectID
        self.agentID = agentID
        self.groupName = groupName
        self.members = members
        self.title = title
        self.titleIsAuto = titleIsAuto
        self.status = status
        self.visibility = visibility
        self.reasoning = reasoning
        self.unread = unread
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, projectID, agentID, groupName, members, title, titleIsAuto, titleIsModelNamed, status, visibility
        case reasoning, unread, createdAt, updatedAt, messages, plan, planMode, parent, boardLayout, groupNameIsAuto, cardTitles
        case earlier, memoryPassAt
    }

    /// Fields added after 6a are optional on disk, so older files still open.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .kind)
        projectID = try values.decode(UUID.self, forKey: .projectID)
        agentID = try values.decodeIfPresent(UUID.self, forKey: .agentID)
        groupName = try values.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        members = try values.decodeIfPresent([GroupMember].self, forKey: .members) ?? []
        title = try values.decode(String.self, forKey: .title)
        titleIsAuto = try values.decodeIfPresent(Bool.self, forKey: .titleIsAuto) ?? true
        titleIsModelNamed = try values.decodeIfPresent(Bool.self, forKey: .titleIsModelNamed) ?? false
        status = try values.decodeIfPresent(ConversationStatus.self, forKey: .status) ?? .pending
        visibility = try values.decodeIfPresent(ConversationVisibility.self, forKey: .visibility) ?? .normal
        reasoning = try values.decodeIfPresent(ReasoningLevel.self, forKey: .reasoning) ?? .auto
        unread = try values.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        messages = try values.decodeIfPresent([Message].self, forKey: .messages) ?? []
        plan = try values.decodeIfPresent([PlanItem].self, forKey: .plan) ?? []
        planMode = try values.decodeIfPresent(Bool.self, forKey: .planMode) ?? false
        parent = try values.decodeIfPresent(SubtaskLink.self, forKey: .parent)
        boardLayout = try values.decodeIfPresent(BoardLayout.self, forKey: .boardLayout)
        groupNameIsAuto = try values.decodeIfPresent(Bool.self, forKey: .groupNameIsAuto) ?? false
        cardTitles = try values.decodeIfPresent([String: String].self, forKey: .cardTitles) ?? [:]
        earlier = try values.decodeIfPresent([EarlierVersion].self, forKey: .earlier) ?? []
        memoryPassAt = try values.decodeIfPresent(Date.self, forKey: .memoryPassAt)
    }

    var isGroup: Bool { kind == .group }
    var isSubtask: Bool { parent != nil }
    /// One member's part of a group message Bob arranged side by side (9e): the member's own work, run in the background.
    var isLane: Bool { parent?.lane == true }
    /// 岔开问一句 (10i).
    var isSide: Bool { parent?.side == true }

    /// The row's second line: the last message, or what's missing.
    var preview: String {
        guard let last = messages.last(where: { !$0.isHidden && $0.event == nil }) else { return isGroup ? "尚未分配任务" : "尚未发送消息" }
        if let failure = last.failure { return "没有回复：\(failure)" }
        let line = last.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        // An Agent writes Markdown (D69): the row shows its words, not the marks; the user's own text as typed.
        let text = last.role == .agent ? Self.plainLine(line) : line
        if !text.isEmpty { return text }
        if let call = last.toolCalls.last { return call.summary }
        return last.attachments.first.map { "[附件] \($0.name)" } ?? "（只有思考过程，没有正文）"
    }

    /// A Markdown line without its marks: the heading's `#`, a quote's `>`, a bullet, bold and code markers.
    static func plainLine(_ line: String) -> String {
        let body = line.drop { "#>*-+ ".contains($0) }
        return String(body).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// Where a subtask came from (7g, S2): the conversation, the reply and the call that opened it, and who asked.
struct SubtaskLink: Codable, Equatable, Sendable {
    var conversationID: UUID
    var messageID: UUID
    /// The delegate call; empty for a goal's check (A3).
    var callID: String
    var requesterID: UUID
    var requesterName: String
    /// Only the read tier: `read_only` (S1), and every goal check.
    var readOnly: Bool
    /// Another Agent checking a goal (A3), not a delegation.
    var isCheck: Bool
    /// A lane of Bob's arrangement (9e): the member works its part of the user's message; its last reply goes to the
    /// group under its own name. Absent in older files.
    var lane: Bool? = nil
    /// 岔开问一句 (10i): the user's quick question beside the conversation — read-only, thrown away on return.
    var side: Bool? = nil
    /// A subagent's run (user 2026-09-15): its name — the prompt, tools and model come from its definition.
    var subagent: String? = nil
}

/// One step of the Agent's plan (7d, D4; omp `todo`, flattened to one list).
struct PlanItem: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending, active, done, dropped
    }

    var id = UUID()
    var text: String
    var status: Status = .pending
    /// Added by the user with `/todo`.
    var byUser = false

    var isOpen: Bool { status == .pending || status == .active }
}

struct GroupMember: Codable, Hashable, Sendable {
    var agentID: UUID
    /// Muted inside this group only: still a member, can't be `@`-ed (C8).
    var isMuted = false
}

/// The status words shared with the board (spec §9.1).
enum ConversationStatus: String, Codable, CaseIterable, Sendable {
    case pending, done

    var label: String {
        switch self {
        case .pending: "进行中"
        case .done: "已完成"
        }
    }
}

/// Spec §9.1b's three steps. One field, so 「archived and hidden」 can't be written down.
enum ConversationVisibility: String, Codable, Sendable {
    case normal, hidden, archived
}

/// omp's thinking selectors (`thinking.ts`), per conversation (user 2026-09-05). 自动 sends nothing and lets
/// the model decide; the rest map to each protocol's own parameter in 6b.
enum ReasoningLevel: String, Codable, CaseIterable, Sendable {
    case auto, off, minimal, low, medium, high, xhigh, max

    var label: String {
        switch self {
        case .auto: "自动"
        case .off: "关闭"
        case .minimal: "极简"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "超高"
        case .max: "最高"
        }
    }

    /// omp's descriptions, in the product's words.
    var note: String {
        switch self {
        case .auto: "由模型自行决定"
        case .off: "不推理，直接回答"
        case .minimal: "很短的推理，约 1k tokens"
        case .low: "轻度推理，约 2k tokens"
        case .medium: "适度推理，约 8k tokens"
        case .high: "深入推理，约 16k tokens"
        case .xhigh: "更长的推理，约 32k tokens"
        case .max: "模型支持的最大推理量"
        }
    }
}

struct Message: Codable, Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user, agent
    }

    var id: UUID
    var role: Role
    /// Who spoke, for Agent messages — a group has several on the left (spec §9.10).
    var agentID: UUID?
    /// The Agent's name when it spoke, so history still reads after it is renamed or deleted.
    var speakerName: String?
    var text: String
    var attachments: [Attachment]
    var createdAt: Date
    // Replies (6b). Every one is optional on disk, so 6a files still open.
    /// What the model showed of its thinking — kept, never sent back.
    var thinking: String?
    var thinkingSeconds: Double?
    /// The model that answered.
    var model: ModelReference?
    var usage: TokenUsage?
    var durationSeconds: Double?
    /// Stopped by the user: `text` is what had arrived.
    var isStopped: Bool
    /// No reply: why. `text` is empty.
    var failure: String?
    /// A line under the reply: a fallback answered, the reasoning level was dropped, it broke off.
    var note: String?
    /// Group chats (6c): the members this message `@`-ed — its assignment.
    var assignees: [UUID]
    // The agent core (7b), optional on disk like the rest.
    /// Tools the model called in this turn, each with its outcome once it ran.
    var toolCalls: [ToolCall]
    /// Anthropic's signature for `thinking`, sent back with a tool-call turn (7b, L7).
    var thinkingSignature: String?
    /// The run this turn belongs to: one run is one frame in the thread (L8).
    var runID: UUID?
    /// Sent to the model, never shown: the loop's own nudges (L3).
    var isHidden: Bool
    /// The run stopped here to ask 「继续？」, and why (L2).
    var pause: String?
    /// The composer (7d): the project files it `@`-ed, as they were when sent.
    var mentions: [FileMention]
    /// A hidden message asking for a self-review (7d, D7): the thread shows this line in its place.
    var marker: String?
    /// A context compaction (7e, E3): the summary the model reads instead of everything before `firstKeptID`.
    var compaction: CompactionRecord?
    /// A call the app made for its own upkeep — the memory extraction (7f, F4): counted in `/cost`, never shown or sent.
    var isUpkeep: Bool
    /// A line the runner wrote between turns (7g): a dispatch, a hand-off, a round, a goal's check, an end.
    var event: ThreadEvent?
    /// Sent from the board (8a, K3, K13): the card this message branches from (an `@` on a focused card), or the card it
    /// adds to (no `@`). Chosen on the canvas, so stored; everything else about cards is derived.
    var boardParent: String?
    var boardCard: String?
    /// A lane's last reply, posted to the group (9e): the lane it came from — its steps are there, and its card.
    var lane: UUID?
    /// A watched rule's reminder (10g): the rule it hands over — once per conversation.
    var rule: String?
    /// A 旁审 note (10h): how strongly — its `marker` is the note the thread shows.
    var advice: Advisor.Severity?
    /// `/review`'s graded review (10k): the thread's card.
    var review: Advisor.Review?

    init(id: UUID = UUID(), role: Role, agentID: UUID? = nil, speakerName: String? = nil, text: String,
         attachments: [Attachment] = [], createdAt: Date = .now, thinking: String? = nil, thinkingSeconds: Double? = nil,
         model: ModelReference? = nil, usage: TokenUsage? = nil, durationSeconds: Double? = nil, isStopped: Bool = false,
         failure: String? = nil, note: String? = nil, assignees: [UUID] = [], toolCalls: [ToolCall] = [],
         thinkingSignature: String? = nil, runID: UUID? = nil, isHidden: Bool = false, pause: String? = nil,
         mentions: [FileMention] = [], marker: String? = nil, compaction: CompactionRecord? = nil, isUpkeep: Bool = false,
         event: ThreadEvent? = nil) {
        self.mentions = mentions
        self.marker = marker
        self.compaction = compaction
        self.isUpkeep = isUpkeep
        self.event = event
        self.assignees = assignees
        self.toolCalls = toolCalls
        self.thinkingSignature = thinkingSignature
        self.runID = runID
        self.isHidden = isHidden
        self.pause = pause
        self.id = id
        self.role = role
        self.agentID = agentID
        self.speakerName = speakerName
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.thinking = thinking
        self.thinkingSeconds = thinkingSeconds
        self.model = model
        self.usage = usage
        self.durationSeconds = durationSeconds
        self.isStopped = isStopped
        self.failure = failure
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, agentID, speakerName, text, attachments, createdAt
        case thinking, thinkingSeconds, model, usage, durationSeconds, isStopped, failure, note, assignees
        case toolCalls, thinkingSignature, runID, isHidden, pause, mentions, marker, compaction, isUpkeep, event
        case boardParent, boardCard, lane, rule, advice, review
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        agentID = try values.decodeIfPresent(UUID.self, forKey: .agentID)
        speakerName = try values.decodeIfPresent(String.self, forKey: .speakerName)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        thinking = try values.decodeIfPresent(String.self, forKey: .thinking)
        thinkingSeconds = try values.decodeIfPresent(Double.self, forKey: .thinkingSeconds)
        model = try values.decodeIfPresent(ModelReference.self, forKey: .model)
        usage = try values.decodeIfPresent(TokenUsage.self, forKey: .usage)
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        isStopped = try values.decodeIfPresent(Bool.self, forKey: .isStopped) ?? false
        failure = try values.decodeIfPresent(String.self, forKey: .failure)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        assignees = try values.decodeIfPresent([UUID].self, forKey: .assignees) ?? []
        toolCalls = try values.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        thinkingSignature = try values.decodeIfPresent(String.self, forKey: .thinkingSignature)
        runID = try values.decodeIfPresent(UUID.self, forKey: .runID)
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        pause = try values.decodeIfPresent(String.self, forKey: .pause)
        mentions = try values.decodeIfPresent([FileMention].self, forKey: .mentions) ?? []
        marker = try values.decodeIfPresent(String.self, forKey: .marker)
        compaction = try values.decodeIfPresent(CompactionRecord.self, forKey: .compaction)
        isUpkeep = try values.decodeIfPresent(Bool.self, forKey: .isUpkeep) ?? false
        event = try values.decodeIfPresent(ThreadEvent.self, forKey: .event)
        boardParent = try values.decodeIfPresent(String.self, forKey: .boardParent)
        boardCard = try values.decodeIfPresent(String.self, forKey: .boardCard)
        lane = try values.decodeIfPresent(UUID.self, forKey: .lane)
        rule = try values.decodeIfPresent(String.self, forKey: .rule)
        advice = try values.decodeIfPresent(Advisor.Severity.self, forKey: .advice)
        review = try values.decodeIfPresent(Advisor.Review.self, forKey: .review)
    }
}

/// A tool the model called (7b), and what came of it once it ran.
extension Message {
    /// A reply that never came (user 2026-09-15: 任务中断要提醒): the failure, 回复中断, or a thinking-only turn — the words to
    /// show and to notify with. `nil` for an answer.
    var interruption: String? {
        if let failure { return failure }
        guard role == .agent, let note else { return nil }
        return note.hasPrefix("回复中断") || note.hasPrefix("模型只返回了思考过程") ? note : nil
    }
}

struct ToolCall: Codable, Equatable, Identifiable, Sendable {
    /// The provider's id, echoed with the result (made up where a protocol has none).
    var id: String
    var name: String
    /// The arguments as the model wrote them: JSON text.
    var arguments: String
    /// Gemini's `thoughtSignature`, sent back with the call (L7).
    var signature: String?
    var result: ToolResult?
    /// delegate (7g, S2): the subtask it opened.
    var subtaskID: UUID?

    init(id: String, name: String, arguments: String, signature: String? = nil, result: ToolResult? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.signature = signature
        self.result = result
    }
}

struct ToolResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case done, failed, denied, stopped
    }

    var status: Status
    /// What the model reads.
    var output: String
    /// write / edit: the file it changed, relative to the project — the save card.
    var savedPath: String?
    var isNewFile: Bool?
    /// ask (7d, D6): what the user picked or wrote, per question — the card shows them.
    var answers: [AskTool.Answer]?
    /// Pruned before a compaction (7e, E3): the model reads a placeholder, the card still shows `output`.
    var pruned: Bool?
    /// Pictures that go to the model with `output` — an image `read`, a screenshot (7j, V1): absolute paths.
    var images: [String]?
    /// From taking the step up to its result, a wait for 允许 included (8c): 「运行过程」 shows it past 5 seconds.
    var seconds: Double?
    /// write / edit (10d): what it changed — the card's diff and its 撤销.
    var change: FileChange?

    static func done(_ output: String) -> ToolResult { ToolResult(status: .done, output: output) }
    static func failed(_ output: String) -> ToolResult { ToolResult(status: .failed, output: output) }
}

/// Tokens one reply used, as the provider reported them.
struct TokenUsage: Codable, Equatable, Sendable {
    /// What the request carried — cache reads and writes included, so it is the context that was sent (7e, E1).
    var input: Int?
    var output: Int?
    /// Of `input`, read from the provider's cache.
    var cached: Int?
    /// Of `output`, spent thinking.
    var reasoning: Int?
}

/// A file the message carries, always inside the project (spec §9.7): its path relative to the project root.
struct Attachment: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image, file
    }

    var id: UUID
    var name: String
    var relativePath: String
    var kind: Kind

    init(id: UUID = UUID(), name: String, relativePath: String, kind: Kind) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
    }
}
