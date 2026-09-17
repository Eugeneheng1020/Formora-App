import Foundation

/// One task on the board (8a, K1–K6): what one Agent was given, what it did, what it handed back.
struct BoardCard: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// Given in a message: an `@`, the dispatcher's pick, a hand-off, a canvas branch.
        case assignment
        /// A delegate call's helper (7g, S2): its run is the subtask's.
        case delegation
        /// A /loop or /goal round (K2: a root, never a child).
        case round
        /// Another Agent checking a goal (7g, A3).
        case check
    }

    /// Six labels, four colour tiers (K5).
    enum Status: Equatable, Sendable {
        case pending, running, done, stopped, failed
        /// Waiting out a transient failure before trying again: 「等待限流」 or 「等待重试」.
        case waiting(String)
        /// A later step of Bob's arrangement (9e): 「等待 产品设计 完成」 until it starts.
        case queued(String)

        enum Tier: Sendable { case neutral, active, success, alert }

        var label: String {
            switch self {
            case .pending: "待开始"
            case .running: "进行中"
            case .waiting(let label), .queued(let label): label
            case .done: "已完成"
            case .stopped: "已停止"
            case .failed: "已失败"
            }
        }

        var tier: Tier {
            switch self {
            case .running: .active
            case .done: .success
            case .failed: .alert
            case .pending, .stopped, .waiting, .queued: .neutral
            }
        }

        var isDone: Bool { self == .done }
    }

    /// One line of the 「运行过程」 transcript (K11).
    struct Entry: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Someone's words: the user's, the Agent's, a brief handed over.
            case said(speaker: String, text: String, isUser: Bool)
            case step(ToolCall)
            /// The model's thinking before its words (9c): 「运行过程」 shows it whole, never folded.
            case thinking(String)
            /// A line of the thread's own: a round, a review, a check's verdict.
            case line(String)
        }

        let id: String
        let kind: Kind
    }

    let id: String
    let agentID: UUID
    var agentName: String
    var title: String
    let kind: Kind
    /// A later step of Bob's arrangement hangs under the step it waits for (9e).
    var parentID: String?
    /// What it was given: the user's words, or the brief handed over.
    var input: String
    /// The message that opened it: 💬 goes there.
    let messageID: UUID
    var entries: [Entry] = []
    /// The output's first paragraph.
    var summary = ""
    /// Files it wrote, relative to the project, in order.
    var files: [String] = []
    var seconds: Double = 0
    var tokens = 0
    var replies = 0
    var status: Status = .pending
    /// A delegation's or a check's subtask, or a lane of Bob's arrangement (9e).
    var subtaskID: UUID?
    /// Whom it waits for, in Bob's arrangement (9e): not started yet, it says 「等待 … 完成」.
    var after: [String] = []
}

/// Cards from a conversation (8a, K1–K4): nothing stored but what the canvas chose.
enum BoardCards {
    /// What the runner says about a conversation right now.
    struct Activity: Equatable, Sendable {
        var runningAgent: UUID?
        /// 「等待限流」 / 「等待重试」 while a run waits out a transient failure.
        var waiting: String?

        init(runningAgent: UUID? = nil, waiting: String? = nil) {
            self.runningAgent = runningAgent
            self.waiting = waiting
        }
    }

    static let titleLimit = 40
    static let summaryLimit = 160

    static func derive(_ conversation: Conversation, name: @escaping (UUID) -> String?, subtask: @escaping (UUID) -> Conversation?,
                       activity: @escaping (UUID) -> Activity) -> [BoardCard] {
        var builder = Builder(conversation: conversation, name: name, subtask: subtask, activity: activity)
        for message in conversation.messages where !message.isUpkeep && message.compaction == nil { builder.take(message) }
        return builder.finish()
    }

    /// The first line, without Markdown's marks or the `@`s that addressed it, at most 40 characters: the card says
    /// who does it above the task.
    static func title(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var plain = line.drop { "#>*- ".contains($0) }.trimmingCharacters(in: .whitespaces)
        while plain.hasPrefix("@"), let space = plain.firstIndex(where: { $0 == " " || $0 == "\u{3000}" }) {
            plain = plain[space...].trimmingCharacters(in: .whitespaces)
        }
        guard !plain.isEmpty else { return "（没有文字）" }
        return plain.count > titleLimit ? String(plain.prefix(titleLimit)) + "…" : plain
    }

    /// An output's first paragraph on one line, at most 160 characters.
    static func summary(of text: String) -> String {
        let paragraph = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        let line = paragraph.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).drop { "#>*- ".contains($0) }.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return line.count > summaryLimit ? String(line.prefix(summaryLimit)) + "…" : line
    }

    private struct Builder {
        let conversation: Conversation
        let name: (UUID) -> String?
        let subtask: (UUID) -> Conversation?
        let activity: (UUID) -> Activity

        var cards: [BoardCard] = []
        var index: [String: Int] = [:]
        /// The card each Agent's turns go into now.
        var current: [UUID: Int] = [:]
        /// The latest card a message opened: a direct follow-up joins it when it is the Agent's (K1).
        var lastOpened: Int?
        /// A group message the dispatcher hasn't placed yet: whoever answers takes it (old fix 2026-09-08).
        var held: Message?
        /// An autorun round: each Agent's first turn in it opens a root card (K2).
        var round: Message?
        var lastSpeaker: UUID?
        var lastTurn: [Int: Message] = [:]
        var runs: [Int: Set<String>] = [:]
        /// Whose direct chat it is — until an `@` on the canvas made it a group (K14): what was said before keeps a
        /// direct chat's cards (old fix 2026-09-08).
        var directAgent: UUID?

        init(conversation: Conversation, name: @escaping (UUID) -> String?, subtask: @escaping (UUID) -> Conversation?,
             activity: @escaping (UUID) -> Activity) {
            self.conversation = conversation
            self.name = name
            self.subtask = subtask
            self.activity = activity
            directAgent = conversation.kind == .direct ? conversation.agentID
                : conversation.messages.lazy.compactMap { $0.event?.kind == .upgrade ? $0.event?.agentID : nil }.first
        }

        func agentName(_ id: UUID, _ fallback: String? = nil) -> String { name(id) ?? fallback ?? "Agent" }

        @discardableResult
        mutating func open(_ id: String, agent: UUID, kind: BoardCard.Kind, parent: String?, title: String, input: String,
                           message: UUID, speaker: String? = nil) -> Int {
            if let existing = index[id] { return existing }
            let parentID = parent.flatMap { index[$0] == nil ? nil : $0 }
            // Bob's title for this card or its message's cards (9e, H), before the first line's.
            let named = conversation.cardTitles[id] ?? conversation.cardTitles[message.uuidString]
            cards.append(BoardCard(id: id, agentID: agent, agentName: agentName(agent, speaker), title: named ?? title, kind: kind,
                                   parentID: parentID, input: input, messageID: message))
            index[id] = cards.count - 1
            return cards.count - 1
        }

        mutating func add(_ entry: BoardCard.Entry.Kind, to card: Int, id: String) {
            cards[card].entries.append(BoardCard.Entry(id: id, kind: entry))
        }

        mutating func take(_ message: Message) {
            if message.role == .agent { return takeTurn(message) }
            if let event = message.event { return takeEvent(event, message) }
            // The loop's own words aren't replayed (K11); a self-review's marker is its line.
            if message.isHidden {
                if let marker = message.marker, let speaker = lastSpeaker, let card = current[speaker] {
                    add(.line(marker), to: card, id: message.id.uuidString)
                }
                return
            }
            round = nil
            let said = BoardCard.Entry.Kind.said(speaker: "你", text: message.text, isUser: true)
            if let target = message.boardCard, let card = index[target] {
                add(said, to: card, id: message.id.uuidString)
                current[cards[card].agentID] = card
                return
            }
            if !message.assignees.isEmpty {
                held = nil
                for agent in message.assignees {
                    let card = open("\(message.id)#\(agent)", agent: agent, kind: .assignment, parent: message.boardParent,
                                    title: BoardCards.title(of: message.text), input: message.text, message: message.id)
                    add(said, to: card, id: "\(message.id)#\(agent)")
                    current[agent] = card
                    lastOpened = card
                }
                return
            }
            guard let agent = directAgent else {
                held = message
                return
            }
            if message.boardParent == nil, let card = current[agent], card == lastOpened {
                add(said, to: card, id: message.id.uuidString)
                return
            }
            let card = open("\(message.id)#\(agent)", agent: agent, kind: .assignment, parent: message.boardParent,
                            title: BoardCards.title(of: message.text), input: message.text, message: message.id)
            add(said, to: card, id: message.id.uuidString)
            current[agent] = card
            lastOpened = card
        }

        mutating func takeEvent(_ event: ThreadEvent, _ message: Message) {
            switch event.kind {
            case .handoff:
                guard let taker = event.agentID else { return }
                let parent = lastSpeaker.flatMap { current[$0] }.map { cards[$0].id }
                let giver = lastSpeaker.map { agentName($0) } ?? "上一位"
                let card = open("\(message.id)#\(taker)", agent: taker, kind: .assignment, parent: parent,
                                title: "接手：" + BoardCards.title(of: event.detail), input: event.detail, message: message.id)
                add(.said(speaker: "\(giver) 的交待", text: event.detail, isUser: false), to: card, id: message.id.uuidString)
                current[taker] = card
                lastOpened = card
            case .round:
                round = message
                current = [:]
                held = nil
            case .autorunEnd:
                round = nil
            case .goalCheck:
                guard let checker = event.agentID, let child = event.subtaskID else { return }
                let card = open("check:\(child)", agent: checker, kind: .check, parent: nil, title: "复核目标",
                                input: subtask(child)?.messages.first { $0.role == .user }?.text ?? "", message: message.id)
                cards[card].subtaskID = child
                fillSubtask(card, child)
                add(.line(event.title), to: card, id: message.id.uuidString)
            case .upgrade:
                // From here on it's a group: an unplaced message waits for whoever answers it.
                directAgent = nil
            case .conduct:
                // Bob's arrangement (9e): the cards the message opened — a lane's filled from its run, a later step
                // hung under the one it waits for.
                guard let plan = event.arrangement else { return }
                for (number, stage) in plan.stages.enumerated() {
                    for agent in stage {
                        guard let card = index["\(plan.messageID)#\(agent)"] else { continue }
                        if number > 0, let before = plan.stages[number - 1].first, let parent = index["\(plan.messageID)#\(before)"] {
                            cards[card].parentID = cards[parent].id
                            cards[card].after = plan.stages[number - 1].map { agentName($0) }
                        }
                        if let lane = plan.lane(of: agent) {
                            cards[card].subtaskID = lane
                            fillSubtask(card, lane)
                        }
                    }
                }
            case .conductEnd:
                // Ended early: a step that never started waits for nobody now.
                guard let plan = event.arrangement else { return }
                for agent in plan.stages.joined() {
                    if let card = index["\(plan.messageID)#\(agent)"] { cards[card].after = [] }
                }
            case .takeover:
                // E (9e): work taken over after a failed reply — a card under the one that failed.
                guard let taker = event.agentID else { return }
                let giver = event.from.map { agentName($0) } ?? "上一位"
                let card = open("\(message.id)#\(taker)", agent: taker, kind: .assignment, parent: event.from.flatMap { current[$0] }.map { cards[$0].id },
                                title: "接手：\(giver) 没做完的活", input: "", message: message.id)
                add(.line(event.title), to: card, id: message.id.uuidString)
                current[taker] = card
                lastOpened = card
            case .subagent:
                // `/agent 目的` from the canvas (user 2026-09-17): what came of it is a line on the card it was typed at —
                // or the one last opened.
                guard let card = message.boardCard.flatMap({ index[$0] }) ?? lastOpened else { return }
                add(.line([event.title, event.detail].filter { !$0.isEmpty }.joined(separator: "\n")), to: card, id: message.id.uuidString)
            case .dispatch, .relayEnd, .summary, .rewind, .memory:
                // The pick is on the message as its assignees; an end, Bob's summary or a message sent again (10e) says
                // nothing about a card.
                break
            }
        }

        mutating func takeTurn(_ message: Message) {
            // A lane's reply posted to the group (9e): its card has it from the lane already.
            guard let agent = message.agentID, !message.isHidden, message.lane == nil else { return }
            let card: Int
            if let waiting = held {
                held = nil
                if let existing = current[agent], let last = lastTurn[existing], last.runID != nil, last.runID == message.runID {
                    // Said while it worked: the run goes on in the same card.
                    card = existing
                    add(.said(speaker: "你", text: waiting.text, isUser: true), to: card, id: waiting.id.uuidString)
                } else {
                    card = open("\(waiting.id)#\(agent)", agent: agent, kind: .assignment, parent: waiting.boardParent,
                                title: BoardCards.title(of: waiting.text), input: waiting.text, message: waiting.id, speaker: message.speakerName)
                    add(.said(speaker: "你", text: waiting.text, isUser: true), to: card, id: waiting.id.uuidString)
                    lastOpened = card
                }
            } else if let opening = round, current[agent] == nil {
                let event = opening.event
                card = open("\(opening.id)#\(agent)", agent: agent, kind: .round, parent: nil, title: event?.title ?? "自主运行",
                            input: (event?.detail).flatMap { $0.isEmpty ? nil : $0 } ?? opening.text, message: opening.id,
                            speaker: message.speakerName)
                add(.line(event?.title ?? "自主运行"), to: card, id: opening.id.uuidString)
                lastOpened = card
            } else if let existing = current[agent] {
                card = existing
            } else {
                card = open("\(message.id)#\(agent)", agent: agent, kind: .assignment, parent: nil,
                            title: BoardCards.title(of: message.text), input: "", message: message.id, speaker: message.speakerName)
                lastOpened = card
            }
            current[agent] = card
            lastSpeaker = agent
            record(message, in: card)
            for call in message.toolCalls {
                guard let child = call.subtaskID, let helper = subtask(child) else { continue }
                let task = Delegation.parse(call.arguments)?.task ?? helper.title
                let delegation = open("\(message.id)#\(call.id)", agent: helper.agentID ?? agent, kind: .delegation, parent: cards[card].id,
                                      title: BoardCards.title(of: task), input: task, message: message.id)
                cards[delegation].subtaskID = child
                if let name = helper.parent?.subagent { cards[delegation].agentName = "子代理「\(name)」" }
                fillSubtask(delegation, child)
            }
        }

        /// An Agent's turn into a card: its words, its steps, its files, its numbers.
        mutating func record(_ message: Message, in card: Int) {
            if let thinking = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !thinking.isEmpty {
                add(.thinking(thinking), to: card, id: "\(message.id)#thinking")
            }
            let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty {
                add(.said(speaker: cards[card].agentName, text: message.text, isUser: false), to: card, id: message.id.uuidString)
                cards[card].summary = BoardCards.summary(of: message.text)
            }
            for call in message.toolCalls {
                add(.step(call), to: card, id: "\(message.id)#\(call.id)")
                if call.result?.status == .done, let path = call.result?.savedPath, !cards[card].files.contains(path) {
                    cards[card].files.append(path)
                }
            }
            cards[card].seconds += message.durationSeconds ?? 0
            cards[card].tokens += (message.usage?.input ?? 0) + (message.usage?.output ?? 0)
            runs[card, default: []].insert(message.runID?.uuidString ?? message.id.uuidString)
            cards[card].replies = runs[card]?.count ?? 0
            lastTurn[card] = message
        }

        /// A subtask's run as the card's: the brief, the helper's words and steps, and its state.
        mutating func fillSubtask(_ card: Int, _ id: UUID) {
            guard let child = subtask(id) else { return }
            // A lane opens on the user's own message, which the card already has (9e); whatever the user adds later is theirs.
            var copied = !child.isLane
            for message in child.messages where !message.isHidden && !message.isUpkeep && message.event == nil {
                if message.role == .user {
                    guard copied else {
                        copied = true
                        continue
                    }
                    add(child.isLane ? .said(speaker: "你", text: message.text, isUser: true)
                            : .said(speaker: "\(child.parent?.requesterName ?? "上一位") 的交待", text: message.text, isUser: false),
                        to: card, id: message.id.uuidString)
                } else {
                    record(message, in: card)
                }
            }
            let now = activity(id)
            if now.runningAgent != nil {
                cards[card].status = now.waiting.map { .waiting($0) } ?? .running
            } else {
                cards[card].status = BoardCards.status(of: lastTurn[card])
            }
        }

        mutating func finish() -> [BoardCard] {
            // A card with a subtask — a delegation, a check, a lane — has its state from that run.
            for card in cards.indices where cards[card].subtaskID == nil {
                cards[card].status = BoardCards.status(of: lastTurn[card])
            }
            let now = activity(conversation.id)
            if let agent = now.runningAgent, let card = current[agent], cards[card].subtaskID == nil {
                cards[card].status = now.waiting.map { .waiting($0) } ?? .running
            }
            // The pill beside the name stays short: one name, or how many (the run panel's line has them all).
            for card in cards.indices where cards[card].status == .pending && !cards[card].after.isEmpty {
                let after = cards[card].after
                cards[card].status = .queued(after.count == 1 ? "等待 \(after[0]) 完成" : "等待 \(after.count) 位完成")
            }
            return cards
        }
    }

    /// A card's state from its last turn: none yet → 待开始.
    static func status(of turn: Message?) -> BoardCard.Status {
        guard let turn else { return .pending }
        if turn.isStopped { return .stopped }
        return turn.failure == nil ? .done : .failed
    }
}

/// A conversation's cards as one chain (K15): the list's avatar and second line.
enum BoardChain {
    enum Status: Equatable, Sendable { case failed, working, done }

    /// First match wins: any failed → 失败; any not done → 进行中; all done → 完成; none → `nil`.
    static func status(_ cards: [BoardCard]) -> Status? {
        guard !cards.isEmpty else { return nil }
        if cards.contains(where: { $0.status == .failed }) { return .failed }
        if cards.contains(where: { !$0.status.isDone }) { return .working }
        return .done
    }

    /// `3/5 个任务已完成，1 个进行中，1 个失败` — the counts the canvas shows (spec checklist 11b).
    static func line(_ cards: [BoardCard]) -> String {
        guard !cards.isEmpty else { return "还没有任务" }
        let done = cards.filter { $0.status.isDone }.count
        let running = cards.filter { $0.status == .running || { if case .waiting = $0.status { true } else { false } }($0) }.count
        let failed = cards.filter { $0.status == .failed }.count
        return "\(done)/\(cards.count) 个任务已完成" + (running > 0 ? "，\(running) 个进行中" : "") + (failed > 0 ? "，\(failed) 个失败" : "")
    }
}
