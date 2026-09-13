import Foundation

/// 9e: Bob arranges a group message among the members — who does it, together or one after another, and a word to
/// each. He works unseen: the thread shows the arrangement, never his reasons.
enum Conductor {
    /// Bob, where a lane's link wants a requester: the lanes are his arrangement, nobody's delegation.
    static let bobID = UUID(uuidString: "B0B00000-0000-4000-8000-000000000000")!

    static let system = """
    你是 Formora 的调度，在后台安排群聊里的成员怎么分工。用户看不到你的回复，程序只照你的安排执行。
    决定三件事：
    1. 谁来做：用户点了名，点名的人每个都要安排，不加别人（点名的人不能接活时除外，那部分从成员里另找）；没点名，从成员里挑——多数消息一个人就够，只有明显能拆开的活才分给几个人；正在别处忙的尽量不挑。
    2. 同时还是接力：互不依赖的部分同时做；后一个要用前一个的产出（先出方案再实现、先实现再测试），就排在后面。可能改到同一个文件的，不要同时做。
    3. 给每个人一句交待：他负责哪一部分、交出什么，不照抄用户的原话。
    只回一行 JSON，不要别的：{"stages": [[{"to": "成员的名字", "brief": "交待"}]]}
    stages 按先后排：同一个 stage 里的人同时开工，下一个 stage 等上一个全部做完再开始。
    """

    struct Member: Equatable {
        let name: String
        let role: String
        let subtitle: String
        let isBusy: Bool
    }

    /// One member's part.
    struct Step: Equatable, Sendable {
        var agentID: UUID
        var brief: String
    }

    /// A member as Bob reads it: name, role, what it does, busy or not.
    static func line(_ member: Member) -> String {
        "- \(member.name)：\(member.role)" + (member.subtitle.isEmpty ? "" : "，\(member.subtitle)") + (member.isBusy ? "（正在别的对话里忙）" : "（空闲）")
    }

    /// The JSON object in a reply, even inside a code fence or with words around it.
    static func jsonObject(_ reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any]
    }

    static func request(message: String, members: [Member], named: [String], unavailable: [String], files: [String],
                        recent: [(speaker: String, text: String)], handover: String?) -> String {
        var lines = ["成员："] + members.map(line)
        lines.append(named.isEmpty ? "\n用户没有点名。" : "\n用户点名：" + named.joined(separator: "、"))
        if !unavailable.isEmpty { lines.append("点名了但现在不能接活：" + unavailable.joined(separator: "、") + "。他们那部分从成员里另找人。") }
        if !files.isEmpty { lines.append("消息提到的文件：" + files.joined(separator: "、")) }
        if !recent.isEmpty {
            lines.append("\n最近的对话：")
            for line in recent { lines.append("〔\(line.speaker)〕\(line.text)") }
        }
        if let handover, !handover.isEmpty { lines.append("\n这条消息接着看板上的一张卡片：\n" + String(handover.prefix(1_500))) }
        lines.append("\n用户的新消息：\n" + String(message.prefix(3_000)))
        return lines.joined(separator: "\n")
    }

    /// The stages as names and briefs, even inside a code fence or with words around it; `nil` when there is none.
    static func parse(_ reply: String) -> [[(to: String, brief: String)]]? {
        guard let raw = jsonObject(reply)?["stages"] as? [Any] else { return nil }
        let stages: [[(to: String, brief: String)]] = raw.compactMap { stage in
            // A stage written as one step, not a list of them, is read as one.
            let steps = stage as? [Any] ?? [stage]
            let parsed: [(to: String, brief: String)] = steps.compactMap { step in
                guard let step = step as? [String: Any],
                      let to = (step["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else { return nil }
                return (to, (step["brief"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return parsed.isEmpty ? nil : parsed
        }
        return stages.isEmpty ? nil : stages
    }

    /// Names to members, each once and in order: names nobody answers to go; an `@`-ed member Bob left out comes last,
    /// one after another — asked for by name, never dropped.
    static func steps(_ stages: [[(to: String, brief: String)]], resolve: (String) -> UUID?, required: [UUID]) -> [[Step]] {
        var seen: Set<UUID> = []
        var result: [[Step]] = stages.compactMap { stage in
            let steps: [Step] = stage.compactMap { item in
                guard let id = resolve(item.to), seen.insert(id).inserted else { return nil }
                return Step(agentID: id, brief: item.brief)
            }
            return steps.isEmpty ? nil : steps
        }
        for id in required where !seen.contains(id) { result.append([Step(agentID: id, brief: "")]) }
        return result
    }

    /// The divider (9e, 「留一条」): 「A、B 同时开始」, 「A → B → C 依次接力」, 「A、B 同时 → C」.
    static func title(_ stages: [[String]]) -> String {
        if stages.count == 1 { return stages[0].joined(separator: "、") + " 同时开始" }
        if stages.allSatisfy({ $0.count == 1 }) { return stages.map { $0[0] }.joined(separator: " → ") + " 依次接力" }
        return stages.map { $0.count > 1 ? $0.joined(separator: "、") + " 同时" : $0[0] }.joined(separator: " → ")
    }

    /// Marks Bob's words to a member: never the user's.
    static let briefMark = "〔调度的安排〕"

    /// What a lane reads before the user's words (hidden): its part, the others' — which it leaves alone — what the group
    /// said lately, and what came with the message.
    static func laneBrief(group: String, brief: String, others: [(name: String, brief: String)], recent: [(speaker: String, text: String)],
                          extra: [String]) -> String {
        var parts = ["\(briefMark)群聊「\(group)」里的这条消息由几位成员同时处理，下一条是用户的原话。"
                     + (brief.isEmpty ? "" : "你负责：\(brief)")]
        if !others.isEmpty {
            parts.append("同时在做的（他们那部分不要动，别改他们会改的文件）：\n"
                         + others.map { "- \($0.name)" + ($0.brief.isEmpty ? "" : "：\($0.brief)") }.joined(separator: "\n"))
        }
        if !recent.isEmpty { parts.append("群里最近的对话：\n" + recent.map { "〔\($0.speaker)〕\($0.text)" }.joined(separator: "\n")) }
        parts.append(contentsOf: extra)
        parts.append("做完后，你最后一条回复会以你的名义发到群里：把结论和交付物写清楚。")
        return parts.joined(separator: "\n\n")
    }

    /// What a member one step later reads before its turn (hidden).
    static func stepBrief(_ brief: String, after: [String]) -> String {
        var line = briefMark
        if !after.isEmpty { line += "\(after.joined(separator: "、")) 那一步已经结束，产出在上面；接着往下做。" }
        if !brief.isEmpty { line += "你负责：\(brief)" }
        return line
    }

    /// E: what the member taking over reads (in the takeover line's message).
    static func takeoverBrief(from name: String, reason: String) -> String {
        "\(briefMark)\(name) 没能做完（出错了：\(reason)）。你接手它的活：看上面用户要的和已经做了的，接着做完。"
    }

    // MARK: C — after a turn

    enum Review: Equatable {
        case done
        case handOn(to: String, brief: String)
    }

    static let reviewSystem = """
    你是 Formora 的调度，在后台看群聊里刚做完的一轮，判断用户要的东西是不是已经做完。用户看不到你的回复，程序只照你的判断执行。
    做完了，或者剩下的要由用户来定（确认、回答、补充信息），回 {"done": true}。
    还没做完、需要另一位成员接着做（方案出来了还没实现、实现了还没测试），回 {"done": false, "to": "成员的名字", "brief": "交待：接着做什么、交出什么"}。
    只交给下面列出的成员；拿不准就算做完。只回一行 JSON，不要别的。
    """

    static func reviewRequest(message: String, speaker: String, reply: String, members: [Member], handedOn: Int) -> String {
        var lines = ["可以接着做的成员："] + members.map(line)
        if handedOn > 0 { lines.append("\n这条消息已经交接了 \(handedOn) 次。") }
        lines.append("\n用户的要求：\n" + String(message.prefix(2_000)))
        lines.append("\n\(speaker) 刚才的回复：\n" + String(reply.prefix(3_000)))
        return lines.joined(separator: "\n")
    }

    /// `nil` when there is no verdict to read — counted as done by the caller.
    static func parseReview(_ reply: String) -> Review? {
        guard let object = jsonObject(reply) else { return nil }
        if object["done"] as? Bool == true { return .done }
        guard let to = (object["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            return object["done"] is Bool ? .done : nil
        }
        return .handOn(to: to, brief: (object["brief"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: E, I — a member for work that lost its own

    static let pickSystem = """
    你是 Formora 的调度，在后台替一件活找合适的成员。用户看不到你的回复。
    按活的性质选岗位；同一个岗位有几个人时，选空闲的。只回一行 JSON，不要别的：{"to": "成员的名字"}
    """

    static func pickRequest(task: String, situation: String, members: [Member]) -> String {
        (["成员："] + members.map(line) + ["\n情况：\(situation)", "\n要做的事：\n" + String(task.prefix(2_000))]).joined(separator: "\n")
    }

    // MARK: D — side by side, then one conclusion

    static let summarySystem = """
    你是 Formora 的 Bob。群里几位成员同时做完了各自的部分，把他们的结果合成一段给用户的结论。
    先一句话说结论；再按人列出要点和交付的文件；最后写还没解决、需要用户定的事，没有就不写。只用结果里有的内容，不要编造。中文，简洁。
    """

    static func summaryRequest(message: String, results: [(name: String, text: String)]) -> String {
        (["用户的要求：\n" + String(message.prefix(2_000))] + results.map { "〔\($0.name)〕\n" + String($0.text.prefix(4_000)) })
            .joined(separator: "\n\n")
    }

    // MARK: G — a goal checked

    static let checkSystem = """
    你是 Formora 的 Bob，复核一个目标是否已经达成。你只能看到下面的目标、执行者给的依据和它这几轮写过的文件（现在的内容）。
    逐项对照目标的每一项交付物找直接证据；证据不足就算未达成。回复第一行只写「达成」或「未达成」，后面写理由；未达成时写清还差什么。
    """

    static func checkRequest(objective: String, evidence: String, executor: String, files: [(path: String, text: String)]) -> String {
        let written = files.isEmpty ? "这几轮没有写过文件。" : "写过的文件：\n" + files.map { "--- \($0.path)\n\($0.text)" }.joined(separator: "\n\n")
        return ["目标：\n" + objective, "\(executor) 说已经达成，给的依据：\n" + String(evidence.prefix(3_000)), written].joined(separator: "\n\n")
    }

    // MARK: H — names

    /// A card's title is Bob's when the message's own first line is long, or there is more than one line.
    static func needsCardTitle(_ text: String) -> Bool {
        BoardCards.title(of: text).count > 16 || text.split(whereSeparator: \.isNewline).count > 1
    }

    // MARK: J — a step waiting for 允许

    static let riskSystem = """
    你是 Formora 的 Bob。一个 Agent 要执行下面这一步，正在等用户点「允许」或「拒绝」。
    用一句大白话（不超过 40 个字）告诉用户这一步会改动什么、可能有什么风险；只是读取、影响很小，就直说。不替用户做决定，不写「建议允许」或「建议拒绝」。只回这一句。
    """

    static func riskRequest(agent: String, summary: String, name: String, arguments: String) -> String {
        "\(agent) 要：\(summary)\n工具：\(name)\n参数：\(arguments.prefix(1_500))"
    }

    /// His sentence: the first line, a label and quotes off, at most 80 characters.
    static func riskLine(_ reply: String) -> String {
        var line = reply.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for label in ["风险：", "风险:", "Bob：", "Bob:"] where line.hasPrefix(label) { line = String(line.dropFirst(label.count)) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'「」“” "))
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    /// A lane's name in the subtask's header: its part, like a task's name (≤ 20 characters).
    static func laneTitle(_ brief: String, message: String) -> String {
        let source = brief.isEmpty ? message : brief
        let line = source.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let title = line.isEmpty ? "一起做的一部分" : line
        return title.count > 20 ? String(title.prefix(20)) + "…" : title
    }
}
