import Foundation
import Observation
import UniformTypeIdentifiers

enum ConversationProblem: Error, Equatable {
    case nameEmpty, nameTooLong, nameTaken
    case tooFewMembers
    case memberUnavailable(String)
    case agentUnavailable(String)
    case titleEmpty, titleTooLong
    case emptyMessage
    case notArchived

    var message: String {
        switch self {
        case .nameEmpty: "群聊名称不能为空"
        case .nameTooLong: "群聊名称不能超过 20 个字符"
        case .nameTaken: "这个项目里已经有同名群聊了"
        case .tooFewMembers: "群聊至少需要 2 个角色"
        case .memberUnavailable(let reason): reason
        case .agentUnavailable(let reason): reason
        case .titleEmpty: "任务名不能为空"
        case .titleTooLong: "任务名不能超过 50 个字符"
        case .emptyMessage: "消息是空的"
        case .notArchived: "只有归档的会话才能删除"
        }
    }
}

/// Every conversation of every project, newest activity first, saved in the background (C19). Main actor only.
/// Rules that need Agents and providers take them as closures, so the store stays testable on its own.
@MainActor
@Observable
final class ConversationStore {
    static let maxGroupNameLength = 20
    static let maxTitleLength = 50
    static let folderName = "Conversations"
    nonisolated static let attachmentsFolder = "附件"

    private(set) var conversations: [Conversation] = []

    @ObservationIgnored private let files: ConversationFiles?

    /// `folder == nil` keeps everything in memory (tests, previews).
    init(folder: URL?) {
        files = folder.map { ConversationFiles(folder: $0) }
        // A side conversation (10i) left open at quit is gone: it never outlives the moment it was for.
        conversations = (files?.load() ?? []).filter { !$0.isSide }
    }

    func conversation(_ id: UUID?) -> Conversation? {
        guard let id else { return nil }
        return conversations.first { $0.id == id }
    }

    /// Waits for pending writes (tests, quitting).
    func flush() { files?.flush() }

    // MARK: Scope (C1–C4)

    func list(project: UUID?, hiddenView: Bool, status: ConversationStatus? = nil) -> [Conversation] {
        let visibility: ConversationVisibility = hiddenView ? .hidden : .normal
        return conversations.filter {
            $0.parent == nil && $0.projectID == project && $0.visibility == visibility && (status == nil || $0.status == status)
        }
    }

    /// The list's order (user 2026-09-15): like a chat app, whatever moved last on top.
    nonisolated static func recent(_ list: [Conversation]) -> [Conversation] { list.sorted { $0.updatedAt > $1.updatedAt } }

    func hiddenCount(project: UUID?) -> Int { list(project: project, hiddenView: true).count }

    /// The files pane's chat (user 2026-09-22): this Agent's latest normal direct chat in this project — hidden and archived
    /// ones are put away, subtasks and side chats aren't the user's own.
    func latestDirect(agentID: UUID, project: UUID) -> Conversation? {
        Self.recent(conversations.filter {
            $0.kind == .direct && $0.agentID == agentID && $0.projectID == project && $0.parent == nil && $0.visibility == .normal
        }).first
    }

    func archived() -> [Conversation] { conversations.filter { $0.parent == nil && $0.visibility == .archived } }

    // MARK: Creating (C6, C7)

    /// 「发起对话」: always a new chat — one Agent may run several tasks side by side.
    @discardableResult
    func startDirect(agentID: UUID, projectID: UUID, blockReason: String?, now: Date = .now) throws -> Conversation {
        if let blockReason { throw ConversationProblem.agentUnavailable(blockReason) }
        let conversation = Conversation(kind: .direct, projectID: projectID, agentID: agentID, title: "新对话", createdAt: now)
        insert(conversation)
        return conversation
    }

    func groupNameProblem(_ raw: String, projectID: UUID, excluding id: UUID? = nil) -> ConversationProblem? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .nameEmpty }
        if name.unicodeScalars.count > Self.maxGroupNameLength { return .nameTooLong }
        let normalized = FileSearch.normalize(name)
        let taken = conversations.contains {
            $0.isGroup && $0.id != id && $0.projectID == projectID && FileSearch.normalize($0.groupName) == normalized
        }
        return taken ? .nameTaken : nil
    }

    /// `reasonFor` answers why an Agent can't take work (`nil` = it can).
    @discardableResult
    func createGroup(name raw: String, memberIDs: [UUID], projectID: UUID, reasonFor: (UUID) -> String?,
                     now: Date = .now) throws -> Conversation {
        if let problem = groupNameProblem(raw, projectID: projectID) { throw problem }
        let unique = memberIDs.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        guard unique.count >= 2 else { throw ConversationProblem.tooFewMembers }
        for id in unique { if let reason = reasonFor(id) { throw ConversationProblem.memberUnavailable(reason) } }
        let conversation = Conversation(kind: .group, projectID: projectID,
                                        groupName: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                        members: unique.map { GroupMember(agentID: $0) }, title: "新任务", createdAt: now)
        insert(conversation)
        return conversation
    }

    /// 群设置 (C8). Members already in the group may stay even if they can't work now; new ones must be able to.
    func updateGroup(_ id: UUID, name raw: String, members: [GroupMember], reasonFor: (UUID) -> String?) throws {
        guard let current = conversation(id), current.isGroup else { return }
        if let problem = groupNameProblem(raw, projectID: current.projectID, excluding: id) { throw problem }
        guard Set(members.map(\.agentID)).count >= 2 else { throw ConversationProblem.tooFewMembers }
        let existing = Set(current.members.map(\.agentID))
        for member in members where !existing.contains(member.agentID) {
            if let reason = reasonFor(member.agentID) { throw ConversationProblem.memberUnavailable(reason) }
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        change(id) {
            // Named by the user now: it no longer follows the task's name (9e, H).
            if $0.groupName != name { $0.groupNameIsAuto = false }
            $0.groupName = name
            $0.members = members
        }
    }

    // MARK: Changing

    /// ✎ in the header (C9): a manual name is never overwritten by automatic naming.
    func rename(_ id: UUID, to raw: String) throws {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { throw ConversationProblem.titleEmpty }
        if title.unicodeScalars.count > Self.maxTitleLength { throw ConversationProblem.titleTooLong }
        change(id) {
            $0.title = title
            $0.titleIsAuto = false
        }
    }

    /// The model's name for the task (7a) — only while no one renamed it by hand, and only once.
    func setModelTitle(_ id: UUID, _ title: String) {
        guard let conversation = conversation(id), conversation.titleIsAuto, !conversation.titleIsModelNamed else { return }
        change(id) {
            $0.title = title
            $0.titleIsModelNamed = true
        }
        // A group named for its task follows the task's name (9e, H).
        if conversation.isGroup, conversation.groupNameIsAuto {
            let name = uniqueGroupName(title, projectID: conversation.projectID, excluding: id)
            change(id) { $0.groupName = name }
        }
    }

    /// Bob's title for the cards a message opened, or for one card (9e, H).
    func setCardTitle(_ title: String, for key: String, in id: UUID) {
        change(id) { $0.cardTitles[key] = title }
    }

    func setVisibility(_ id: UUID, _ visibility: ConversationVisibility) {
        change(id) { $0.visibility = visibility }
    }

    /// Only from 设置 → 归档 (spec §9.1b).
    func delete(_ id: UUID) throws {
        guard let conversation = conversation(id) else { return }
        guard conversation.visibility == .archived else { throw ConversationProblem.notArchived }
        // Its subtasks go with it (7g).
        conversations.removeAll { $0.id == id || $0.parent?.conversationID == id }
        persist()
    }

    /// 进行中 / 已完成 — written by the agent core when a task ends (phase 7); the hooks seed it.
    func setStatus(_ id: UUID, _ status: ConversationStatus) {
        change(id) { $0.status = status }
    }

    /// The board's positions and auto / custom (8b, K7), kept with the conversation — moving a card isn't activity,
    /// so the list's order doesn't change.
    func setBoardLayout(_ layout: BoardLayout?, in id: UUID) {
        change(id) { $0.boardLayout = layout }
    }

    func setReasoning(_ id: UUID, _ level: ReasoningLevel) {
        change(id) { $0.reasoning = level }
    }

    /// A reply landed where the user isn't looking.
    func incrementUnread(_ id: UUID) {
        change(id) { $0.unread += 1 }
    }

    /// The rail badge: every unread reply of the project outside 归档.
    func unreadTotal(project: UUID?) -> Int {
        conversations.filter { $0.parent == nil && $0.projectID == project && $0.visibility != .archived }.reduce(0) { $0 + $1.unread }
    }

    /// 重试 takes the failed reply away before asking again.
    func removeMessage(_ messageID: UUID, from id: UUID) {
        change(id) { $0.messages.removeAll { $0.id == messageID } }
    }

    /// A tool call's outcome lands on the message that made it (7b).
    func setToolResult(_ result: ToolResult, call callID: String, message messageID: UUID, in id: UUID) {
        change(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
                  let call = conversation.messages[index].toolCalls.firstIndex(where: { $0.id == callID }) else { return }
            conversation.messages[index].toolCalls[call].result = result
        }
    }

    /// Every call that never ran gets `result`, so no call is left unanswered in the history (7b, L1).
    func closeOpenCalls(in id: UUID, _ result: ToolResult) {
        guard conversation(id)?.messages.contains(where: { $0.toolCalls.contains { $0.result == nil } }) == true else { return }
        change(id) { conversation in
            for index in conversation.messages.indices {
                for call in conversation.messages[index].toolCalls.indices where conversation.messages[index].toolCalls[call].result == nil {
                    conversation.messages[index].toolCalls[call].result = result
                }
            }
        }
    }

    /// The run stopped on this message to ask 「继续？」 (7b, L2).
    func setPause(_ reason: String, message messageID: UUID, in id: UUID) {
        change(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].pause = reason
        }
    }

    /// The line under a message (a hook stopped the run, 7b′).
    func setNote(_ note: String, message messageID: UUID, in id: UUID) {
        change(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].note = note.isEmpty ? nil : note
        }
    }

    func clearPauses(in id: UUID) {
        guard conversation(id)?.messages.contains(where: { $0.pause != nil }) == true else { return }
        change(id) { conversation in
            for index in conversation.messages.indices { conversation.messages[index].pause = nil }
        }
    }

    /// Tool results the model reads as placeholders from now on (7e, E3); the cards keep the output.
    func prune(_ calls: [(message: UUID, call: String)], in id: UUID) {
        guard !calls.isEmpty else { return }
        change(id) { conversation in
            for (messageID, callID) in calls {
                guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
                      let call = conversation.messages[index].toolCalls.firstIndex(where: { $0.id == callID }) else { continue }
                conversation.messages[index].toolCalls[call].result?.pruned = true
            }
        }
    }

    /// A compaction's figures once the context after it is known.
    func setCompaction(_ record: CompactionRecord, message messageID: UUID, in id: UUID) {
        change(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].compaction = record
        }
    }

    /// The `plan` tool's list (7d, D4).
    /// QA only (`-FormoraSeedUsage YES`, 2026-09-14): seeded replies get the Agent's model and a usage when they have none.
    func qaStampUsage(model: (UUID?) -> ModelReference?) {
        for conversation in conversations {
            change(conversation.id) { conversation in
                for index in conversation.messages.indices where conversation.messages[index].role == .agent {
                    if conversation.messages[index].model == nil { conversation.messages[index].model = model(conversation.messages[index].agentID) }
                    if conversation.messages[index].usage == nil { conversation.messages[index].usage = TokenUsage(input: 3_200, output: 640) }
                }
            }
        }
    }

    func setPlan(_ plan: [PlanItem], in id: UUID) {
        guard conversation(id)?.plan != plan else { return }
        change(id) { $0.plan = plan }
    }

    /// `/todo 文字`: the user's own step, at the end.
    func addPlanItem(_ text: String, in id: UUID) {
        change(id) { conversation in
            guard !conversation.plan.contains(where: { $0.text == text }) else { return }
            conversation.plan.append(PlanItem(text: text, byUser: true))
            PlanTool.normalize(&conversation.plan)
        }
    }

    func setMemoryPass(_ date: Date, in id: UUID) {
        change(id) { $0.memoryPassAt = date }
    }

    /// 撤销 on a memory line (user 2026-09-17): the line stays and says so.
    func markMemoryUndone(_ messageID: UUID, in id: UUID) {
        change(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].event?.undone = true
        }
    }

    /// `/plan` (D5).
    func setPlanMode(_ isOn: Bool, in id: UUID) {
        guard conversation(id)?.planMode != isOn else { return }
        change(id) { $0.planMode = isOn }
    }

    /// `/clear` (7d): the words go, the conversation and its place in the list stay.
    func clearMessages(_ id: UUID) {
        change(id) { conversation in
            conversation.messages = []
            conversation.plan = []
            conversation.status = .pending
            conversation.unread = 0
        }
        // Its subtasks go with the words that opened them (7g).
        if conversations.contains(where: { $0.parent?.conversationID == id }) {
            conversations.removeAll { $0.parent?.conversationID == id }
            persist()
        }
    }

    /// 10e: back to `messageID` — it and everything after it leave the thread for an earlier version. Nothing stands
    /// in their place (user 2026-09-20: 「只需要显示修改后的，无需看之前的版本」): the thread reads as though the edited
    /// message is what was sent. The version is still kept — `/cost` counts what those calls cost, and a message the
    /// hook keeps back is put straight back — and the line marking it is hidden, which is what `restore` cuts at.
    /// Back to the first words, the task may be named again from the new ones. `nil`: no such message.
    @discardableResult
    func rewind(_ id: UUID, from messageID: UUID, now: Date = .now) -> EarlierVersion? {
        guard let current = conversation(id), let index = current.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let version = EarlierVersion(replacedAt: now, messages: Array(current.messages[index...]))
        let isFirst = !current.messages[..<index].contains { $0.role == .user && !$0.isHidden && $0.event == nil }
        change(id) {
            $0.messages.removeSubrange(index...)
            $0.earlier.append(version)
            if isFirst, $0.titleIsAuto { $0.titleIsModelNamed = false }
        }
        let event = ThreadEvent(kind: .rewind, title: "你改过下面这条消息，重新发送了", versionID: version.id)
        append(Message(role: .user, text: "", createdAt: now, isHidden: true, event: event), to: id)
        return version
    }

    /// 10e: the message didn't go again (a hook kept it) — the thread as it was before `rewind`.
    func restore(_ version: EarlierVersion, in id: UUID) {
        guard let index = conversation(id)?.messages.firstIndex(where: { $0.event?.versionID == version.id }) else { return }
        change(id) {
            $0.messages.removeSubrange(index...)
            $0.messages += version.messages
            $0.earlier.removeAll { $0.id == version.id }
        }
    }

    func markRead(_ id: UUID) {
        guard conversation(id)?.unread != 0 else { return }
        change(id) { $0.unread = 0 }
    }

    /// The user's message. The first one names the task until the model can (C10).
    @discardableResult
    func send(_ id: UUID, text raw: String, attachments: [Attachment] = [], assignees: [UUID] = [], mentions: [FileMention] = [],
              boardParent: String? = nil, boardCard: String? = nil, now: Date = .now) throws -> Message {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { throw ConversationProblem.emptyMessage }
        var message = Message(role: .user, text: text, attachments: attachments, createdAt: now, assignees: assignees, mentions: mentions)
        // Chosen on the canvas (8d, K3): the card it branches from, or the one it adds to.
        message.boardParent = boardParent
        message.boardCard = boardCard
        append(message, to: id)
        return message
    }

    /// `@` on the canvas (8d, K14): Agents not in the conversation join it in place — same id, the canvas stays. A
    /// direct chat becomes a group named by its task (old fix 2026-09-08); the thread gets a divider saying so.
    func join(_ id: UUID, agents joining: [UUID], names: (UUID) -> String, reasonFor: (UUID) -> String?) throws {
        guard let current = conversation(id) else { return }
        let present = current.isGroup ? current.members.map(\.agentID) : [current.agentID].compactMap { $0 }
        let added = joining.reduce(into: [UUID]()) { if !present.contains($1), !$0.contains($1) { $0.append($1) } }
        guard !added.isEmpty else { return }
        for agent in added { if let reason = reasonFor(agent) { throw ConversationProblem.memberUnavailable(reason) } }
        // The mockup's words (`dividerHtml`), the group's name after them: it is how the chat is found from now on.
        let who = added.map { "「\(names($0))」" }.joined(separator: "、")
        let name = current.isGroup ? current.groupName : uniqueGroupName(current.title, projectID: current.projectID, excluding: id)
        let event = current.isGroup ? ThreadEvent(kind: .upgrade, title: "\(who)加入了群聊")
            : ThreadEvent(kind: .upgrade, title: "已把\(who)加入，现在是群聊「\(name)」", agentID: current.agentID)
        change(id) {
            $0.members = ($0.isGroup ? $0.members : present.map { GroupMember(agentID: $0) }) + added.map { GroupMember(agentID: $0) }
            $0.kind = .group
            $0.groupName = name
            if !current.isGroup { $0.groupNameIsAuto = true }
            $0.agentID = nil
        }
        append(Message(role: .user, text: "〔\(event.title)〕", event: event), to: id)
    }

    /// A group name nobody in the project has, from `base`: 「会员体系」, else 「会员体系 2」, 「会员体系 3」…
    func uniqueGroupName(_ base: String, projectID: UUID, excluding id: UUID? = nil) -> String {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.unicodeScalars.count > Self.maxGroupNameLength - 4 { root.removeLast() }
        if root.isEmpty { root = "群聊" }
        var candidate = root
        var number = 2
        while groupNameProblem(candidate, projectID: projectID, excluding: id) != nil, number < 1000 {
            candidate = "\(root) \(number)"
            number += 1
        }
        return candidate
    }

    /// Adds any message and moves the conversation to the top.
    func append(_ message: Message, to id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var conversation = conversations.remove(at: index)
        // The user's own words — not a line or a nudge (10e: sent again after going back to the first, it names the task).
        let isOwn: (Message) -> Bool = { $0.role == .user && !$0.isHidden && $0.event == nil }
        let isFirstUserMessage = isOwn(message) && !conversation.messages.contains(where: isOwn)
        conversation.messages.append(message)
        conversation.updatedAt = message.createdAt
        if isFirstUserMessage, conversation.titleIsAuto, let title = ConversationText.fallbackTitle(from: message.text) {
            conversation.title = title
        }
        conversations.insert(conversation, at: 0)
        persist()
    }

    // MARK: Subtasks (7g, S2)

    /// A subtask: a direct conversation for the helper, kept out of the list; its brief comes as the first message.
    @discardableResult
    func openSubtask(projectID: UUID, agentID: UUID, title: String, link: SubtaskLink, now: Date = .now) -> Conversation {
        var conversation = Conversation(kind: .direct, projectID: projectID, agentID: agentID, title: title, titleIsAuto: false,
                                        createdAt: now)
        conversation.parent = link
        insert(conversation)
        return conversation
    }

    /// 10i: a side conversation — hidden like a subtask, read-only, starting from the main conversation as reference.
    @discardableResult
    func openSide(from parent: Conversation, agentID: UUID, title: String, now: Date = .now) -> Conversation {
        let link = SubtaskLink(conversationID: parent.id, messageID: parent.messages.last?.id ?? parent.id, callID: "", requesterID: agentID,
                               requesterName: parent.isGroup ? parent.groupName : parent.title, readOnly: true, isCheck: false, side: true)
        let side = openSubtask(projectID: parent.projectID, agentID: agentID, title: title, link: link, now: now)
        append(Message(role: .user, text: Side.context(parent), createdAt: now, isHidden: true), to: side.id)
        return conversation(side.id) ?? side
    }

    /// 10i: gone on return, or when the user goes elsewhere — nothing of it goes back.
    func removeSide(_ id: UUID) {
        guard conversation(id)?.isSide == true else { return }
        conversations.removeAll { $0.id == id }
        persist()
    }

    /// The delegate call remembers its subtask: the card opens it.
    func setSubtask(_ subtaskID: UUID, call callID: String, message messageID: UUID, in id: UUID) {
        change(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }),
                  let call = conversation.messages[index].toolCalls.firstIndex(where: { $0.id == callID }) else { return }
            conversation.messages[index].toolCalls[call].subtaskID = subtaskID
        }
    }

    func subtasks(of id: UUID) -> [Conversation] { conversations.filter { $0.parent?.conversationID == id } }

    /// The dispatcher's pick (7g, M1) is written on the message, as if it had been `@`-ed.
    func setAssignees(_ assignees: [UUID], message messageID: UUID, in id: UUID) {
        change(id) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].assignees = assignees
        }
    }

    /// C17: direct chats keep the id (and read 「已删除的 Agent」); groups drop the member.
    func agentDeleted(_ agentID: UUID) {
        var changed = false
        for index in conversations.indices where conversations[index].members.contains(where: { $0.agentID == agentID }) {
            conversations[index].members.removeAll { $0.agentID == agentID }
            changed = true
        }
        if changed { persist() }
    }

    func count(ofAgent agentID: UUID) -> Int {
        conversations.filter { $0.parent == nil && ($0.agentID == agentID || $0.members.contains { $0.agentID == agentID }) }.count
    }

    // MARK: Search (C15)

    struct SearchHit: Equatable {
        let conversationID: UUID
        /// The first message that matches, when the match is inside the history.
        let messageID: UUID?
        let snippet: String?
    }

    /// Names, task names and every message, folded like the file tree's search; `list` order is kept.
    func search(_ query: String, in list: [Conversation], name: (Conversation) -> String) -> [SearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return list.compactMap { conversation in
            if let message = conversation.messages.last(where: { !$0.isHidden && ConversationText.matches($0.text, query) }) {
                return SearchHit(conversationID: conversation.id, messageID: message.id,
                                 snippet: ConversationText.snippet(of: message.text, matching: query))
            }
            if ConversationText.matches("\(name(conversation)) \(conversation.title)", query) {
                return SearchHit(conversationID: conversation.id, messageID: nil, snippet: nil)
            }
            return nil
        }
    }

    // MARK: Attachments (C13)

    /// A file inside the project is referenced where it is; anything else is copied into `附件/`.
    nonisolated static func importAttachment(from url: URL, projectRoot: URL) throws -> Attachment {
        let root = projectRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return Attachment(name: url.lastPathComponent, relativePath: String(path.dropFirst(root.count + 1)), kind: kind(of: url))
        }
        let target = try uniqueTarget(named: url.lastPathComponent, in: projectRoot)
        try FileManager.default.copyItem(at: url, to: target)
        return Attachment(name: target.lastPathComponent, relativePath: "\(attachmentsFolder)/\(target.lastPathComponent)", kind: kind(of: url))
    }

    /// A pasted image becomes a PNG in `附件/`.
    nonisolated static func savePastedImage(_ png: Data, projectRoot: URL, now: Date = .now) throws -> Attachment {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let target = try uniqueTarget(named: "粘贴图片 \(formatter.string(from: now)).png", in: projectRoot)
        try png.write(to: target, options: .atomic)
        return Attachment(name: target.lastPathComponent, relativePath: "\(attachmentsFolder)/\(target.lastPathComponent)", kind: .image)
    }

    /// `名字.png`, then `名字 2.png`, `名字 3.png` …
    nonisolated private static func uniqueTarget(named name: String, in projectRoot: URL) throws -> URL {
        let folder = projectRoot.appendingPathComponent(attachmentsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    nonisolated private static func kind(of url: URL) -> Attachment.Kind {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true ? .image : .file
    }

    /// QA only (`-FormoraImportConversation`): a conversation saved by another copy of Formora, whole.
    func qaImport(_ conversation: Conversation) { insert(conversation) }

    // MARK: Internals

    private func insert(_ conversation: Conversation) {
        conversations.insert(conversation, at: 0)
        persist()
    }

    private func change(_ id: UUID, _ body: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        body(&conversations[index])
        persist()
    }

    private func persist() {
        files?.saveInBackground(conversations)
    }
}

/// Who a conversation is with and whether it can take a message — one judgement for the list, the header,
/// the composer and sending (spec §9.6: the composer's lock and the send guard use the same rule).
@MainActor
enum ConversationReadiness {
    static let deletedAgentName = "已删除的 Agent"

    /// List line 1: the Agent (group: the group name).
    static func headline(of conversation: Conversation, agents: AgentStore) -> String {
        if conversation.isGroup { return conversation.groupName }
        if let name = conversation.parent?.subagent { return "子代理「\(name)」" }
        return agents.agent(conversation.agentID)?.displayName ?? deletedAgentName
    }

    static func members(of conversation: Conversation, agents: AgentStore) -> [AgentRecord] {
        conversation.members.compactMap { agents.agent($0.agentID) }
    }

    static func blockReason(of conversation: Conversation, agents: AgentStore, currentProject: ProjectRecord?,
                            providers: ProviderStore) -> String? {
        guard conversation.isGroup else {
            guard let agent = agents.agent(conversation.agentID) else { return "这个 Agent 已被删除，历史记录还在，但不能再发消息" }
            return AgentReadiness.blockReason(of: agent, currentProject: currentProject, providers: providers)
        }
        let members = members(of: conversation, agents: agents)
        if members.count < 2 { return "群里只剩 \(members.count) 个成员，去「群设置」加人后才能发消息" }
        let muted = Set(conversation.members.filter(\.isMuted).map(\.agentID))
        let working = members.filter {
            !muted.contains($0.id) && AgentReadiness.blockReason(of: $0, currentProject: currentProject, providers: providers) == nil
        }
        // Spec §9.10: one member who can work keeps the group usable; the others are stopped at `@`.
        return working.isEmpty ? "群里没有一个角色能接活，去「Agent」检查激活状态、项目权限和模型配置" : nil
    }

    /// Why this member can't take the task it was `@`-ed for — the `@` list greys it with this, and sending
    /// checks it again because a name can be typed by hand (spec §9.10, the fifth place of §8.7's judgement).
    static func assignmentReason(_ agent: AgentRecord, in conversation: Conversation, currentProject: ProjectRecord?,
                                 providers: ProviderStore) -> String? {
        if conversation.members.first(where: { $0.agentID == agent.id })?.isMuted == true { return "在这个群里停用了，去「群设置」打开" }
        return AgentReadiness.blockReason(of: agent, currentProject: currentProject, providers: providers)
    }
}
