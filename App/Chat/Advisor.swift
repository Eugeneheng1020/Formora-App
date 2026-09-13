import Foundation

/// 10h: 旁审 — a second model watching the Agent work (omp's advisor: `docs/advisor-watchdog.md`,
/// `prompts/advisor/system.md`), in place of 7d's self-review (user 2026-09-13: 「第八点和我做的/review不就是一个，把我的
/// review功能做成这样吧」). After a step that changed something, and on a run's last answer, it reads what is new —
/// the words, the calls, what came back — and says nothing, or one note: 提醒, 担心 or 必须停. It never runs a tool.
enum Advisor {
    enum Severity: String, Codable, Sendable, CaseIterable {
        case nit, concern, blocker

        var label: String {
            switch self {
            case .nit: "提醒"
            case .concern: "担心"
            case .blocker: "必须停"
            }
        }
    }

    struct Note: Equatable, Sendable {
        let severity: Severity
        let text: String
    }

    /// After a note that interrupts, the steps left alone — room to act on it (omp `advisor.immuneTurns`).
    static let quietSteps = 2

    /// Never shown: the watcher's instructions (omp's advisor prompt, in the product's words).
    static let system = """
    你是 Formora 的旁审：在旁边看另一个 Agent 干活，替用户把关。它看不到你的思考，只会收到你写下的一条意见。
    你看的是它刚做完的一步，或者它这一轮最后的回答：它说了什么、调用了什么工具、结果是什么。
    只在有具体问题时开口：
    - 做错了：和用户的要求对不上、漏了明确的约束、改错了地方、结果和它说的不一致。
    - 没做完就说做完了：用占位、假数据、TODO 代替真正的实现；该验证的没验证就交付。
    - 方向不对：在原地打转、反复做同一件事、明明有更直接的办法。
    不要做的：
    - 不要让它去问用户、确认范围、复述要求；不要质疑用户的要求。
    - 不要挑措辞、风格和规模；改得多、重写得多本身不是问题。
    - 不要重复它已经看到的报错和失败，不要重复你说过的意见。
    - 拿不准就不说。它走在正路上时，不说话最好。
    只有两种回答：
    - 没有意见：只回「没有」。
    - 有意见：只写一条。开头写级别：【提醒】、【担心】或【必须停】，后面直接对它说问题在哪、怎么改，一两句话。
      【提醒】是小问题，它接着做就行；【担心】是可能做错了，由它判断；【必须停】是再做下去会白做或者交出坏结果。
    """

    /// What the watcher reads: the user's ask, who works, and what is new.
    static func request(ask: String, agent: String, role: String, steps: [Message], final: Bool, focus: String? = nil) -> String {
        var lines = ["用户的要求：\n" + String(ask.prefix(2_000))]
        lines.append("\n干活的是「\(agent)」（\(role)）。" + (final ? "下面是它这一轮做的事，最后它说做完了：" : "下面是它刚做完的一步："))
        if let focus, !focus.isEmpty { lines.append("用户要你重点看：\(focus)") }
        lines.append(transcript(steps))
        return lines.joined(separator: "\n")
    }

    /// The steps as text: its words, each call with what it was given and what came back — long parts cut. Its own
    /// notes aren't read again (omp filters them out).
    static func transcript(_ steps: [Message]) -> String {
        var out: [String] = []
        for message in steps where !message.isUpkeep && message.advice == nil && message.review == nil {
            if message.role == .user {
                // What reached it meanwhile — the user's words, a hook's, a rule's: one line each.
                let text = message.marker ?? message.text
                if !text.isEmpty { out.append("〔插进来的话〕" + String(text.prefix(300))) }
                continue
            }
            if !message.text.isEmpty { out.append("它说：" + String(message.text.prefix(3_000))) }
            for call in message.toolCalls {
                out.append("调用 \(call.name)：" + String(call.arguments.prefix(2_000)))
                if let result = call.result { out.append("结果（\(result.status)）：" + String(result.output.prefix(1_500))) }
            }
            if let failure = message.failure { out.append("出错：" + failure) }
        }
        return out.joined(separator: "\n")
    }

    /// 没有 — or a note headed by its level. Anything else, or a note with nothing in it, is silence.
    static func parse(_ reply: String) -> Note? {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        for severity in Severity.allCases {
            let heads = ["【\(severity.label)】", "[\(severity.label)]", "\(severity.label)：", "\(severity.label):"]
            guard let head = heads.first(where: { text.hasPrefix($0) }) else { continue }
            let body = String(text.dropFirst(head.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = body.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard body.count >= 4, !["没有", "没问题", "没有意见", "继续", "很好", "可以"].contains(bare) else { return nil }
            return Note(severity: severity, text: String(body.prefix(600)))
        }
        return nil
    }

    /// The note as it reaches the Agent — words to weigh, not orders — and as the thread's card.
    static func message(_ note: Note, agentID: UUID, runID: UUID) -> Message {
        var message = Message(role: .user, agentID: agentID,
                              text: "〔旁审的意见 · \(note.severity.label)（它在旁边看你干活；由你判断，不必盲从）〕\n\(note.text)",
                              runID: runID, isHidden: true, marker: note.text)
        message.advice = note.severity
        return message
    }

    /// `/review` with nothing to say.
    static func clear(agentID: UUID, runID: UUID) -> Message {
        Message(role: .user, agentID: agentID, text: "〔旁审看过了，没有意见〕", runID: runID, isHidden: true, marker: "旁审：看过了，没有要提的")
    }

    static func isSame(_ message: Message, _ note: Note) -> Bool { message.advice != nil && message.marker == note.text }

    // MARK: /review — a full review, graded (10k; omp `prompts/agents/reviewer.md`)

    /// One problem a review found: P0 blocks delivery, P1 fix now, P2 later, P3 nice to have.
    struct Finding: Codable, Equatable, Sendable {
        var level: Int
        var title: String
        var place: String?
        var detail: String

        var label: String { "P\(level)" }
        var meaning: String { ["挡住交付", "这次就该修", "以后修", "可改可不改"][min(max(level, 0), 3)] }
    }

    struct Review: Codable, Equatable, Sendable {
        /// Deliverable as it is: no P0 or P1.
        var passes: Bool
        var summary: String
        /// From P0 down.
        var findings: [Finding]
    }

    /// Never shown: the review's instructions (omp's reviewer — its priorities and verdict, in the product's words).
    static let reviewSystem = """
    你是 Formora 的旁审。用户请你把另一个 Agent 最近一轮做的事完整审一遍，替用户把关。你只看它做了什么，不自己动手。
    找的是会让结果出错、做不下去、或者和用户要求对不上的问题：写错的内容、漏掉的约束、说做完了其实没做完、该验证的没验证。措辞、风格和个人偏好不算问题。
    每个问题定一个级别：
    - P0：挡住交付，交出去就是错的、会造成损失。
    - P1：这次就该修。
    - P2：以后再修也行。
    - P3：可改可不改。
    只回一个 JSON，不要别的：
    {"verdict": "可以交付" 或 "需要改", "summary": "一到三句话的结论", "findings": [{"level": 0 到 3, "title": "一句话说要改什么，不超过 30 字", "place": "文件路径或位置，可以不写", "detail": "问题是什么、什么情况下会出事、影响是什么，一段话"}]}
    有 P0 或 P1 就是「需要改」；没有问题时 findings 是空的。拿不准的不要写。
    """

    /// The review in the reply — fenced or with words around it. The levels decide: a P0 or P1 isn't deliverable,
    /// whatever the verdict says. `nil`: no review to read.
    static func parseReview(_ reply: String) -> Review? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8))) as? [String: Any] else { return nil }
        let summary = (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let findings = (object["findings"] as? [[String: Any]] ?? []).compactMap { item -> Finding? in
            let level = (item["level"] as? Int) ?? (item["level"] as? String).flatMap { Int($0.filter(\.isNumber)) }
            guard let level, (0...3).contains(level),
                  let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
            let place = (item["place"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Finding(level: level, title: String(title.prefix(80)), place: place?.isEmpty == false ? place : nil,
                           detail: (item["detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { $0.level < $1.level }
        guard !summary.isEmpty || !findings.isEmpty || object["verdict"] != nil else { return nil }
        let passes = !findings.contains { $0.level <= 1 }
        return Review(passes: passes, summary: summary.isEmpty ? (passes ? "看过了，可以交付。" : "有要改的地方。") : summary, findings: findings)
    }

    /// The review as the Agent reads it — P0 and P1 to fix first — and as the thread's card.
    static func message(_ review: Review, agentID: UUID, runID: UUID) -> Message {
        var lines = ["〔旁审的审查结论：\(review.passes ? "可以交付" : "需要改")〕", review.summary]
        for finding in review.findings {
            let place = finding.place.map { "（\($0)）" } ?? ""
            let detail = finding.detail.isEmpty ? "" : "：\(finding.detail)"
            lines.append("- \(finding.label)（\(finding.meaning)）\(finding.title)\(place)\(detail)")
        }
        if !review.passes { lines.append("先把 P0、P1 改掉；P2、P3 由你判断。") }
        var message = Message(role: .user, agentID: agentID, text: lines.joined(separator: "\n"), runID: runID, isHidden: true,
                              marker: review.summary)
        message.review = review
        return message
    }
}
