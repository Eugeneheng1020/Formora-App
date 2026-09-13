import Foundation

/// The `plan` tool (7d, D4): Plan-and-Execute as one step of the ReAct loop (old app 2026-09-06). omp's `todo`,
/// flattened to one list — the Agents here plan a document or a small build, not a multi-phase migration. One step
/// is in progress at a time; a call that can't be applied changes nothing and says why.
enum PlanTool {
    static let spec = ToolSpec(
        name: "plan",
        description: "Keep the plan of the current task: a short list of steps the user sees above the input box. Make one when the work takes three or more steps, or the user gave a list (then every item is its own step); not for a quick answer. op `init` with items replaces the list; `start` marks one item in progress; `done` / `drop` mark an item finished / abandoned (without item: every open one); `append` adds items; `view` shows the list. Refer to items by their exact text. Items are short: what, not how. Mark an item done as soon as it is finished, and send plan calls together with real work, not as a turn of their own.",
        parameters: #"{"type":"object","properties":{"op":{"type":"string","enum":["init","start","done","drop","append","view"]},"items":{"type":"array","items":{"type":"string"},"description":"Steps, for init and append"},"item":{"type":"string","description":"The exact text of one step, for start, done and drop"}},"required":["op"]}"#,
        tier: .read)

    struct Outcome: Equatable {
        var plan: [PlanItem]
        var result: ToolResult
    }

    static func apply(_ json: String, to current: [PlanItem]) -> Outcome {
        func fail(_ reason: String) -> Outcome { Outcome(plan: current, result: .failed(reason + "。计划没有改动。\n\n" + summary(current))) }
        guard let args = ToolArguments.parse(json) else { return fail("参数不是合法的 JSON 对象") }
        let items = ((args["items"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rawItem = (args["item"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let item: String? = rawItem.isEmpty ? nil : rawItem
        // A missing op is repaired only when the shape says it (omp `resolveTodoParams`).
        let op = (args["op"] as? String) ?? (items.isEmpty ? "" : current.isEmpty ? "init" : "append")
        var plan = current
        switch op {
        case "init":
            guard !items.isEmpty else { return fail("init 需要 items：步骤列表") }
            guard Set(items).count == items.count else { return fail("items 里有重复的步骤") }
            plan = items.map { PlanItem(text: $0) }
        case "append":
            guard !items.isEmpty else { return fail("append 需要 items：要加的步骤") }
            for text in items {
                guard !plan.contains(where: { $0.text == text }) else { return fail("「\(text)」已经在计划里了") }
                plan.append(PlanItem(text: text))
            }
        case "start":
            guard let item else { return fail("start 需要 item：步骤的原文") }
            guard let index = find(item, in: plan) else { return fail(notFound(item, in: plan)) }
            for other in plan.indices where plan[other].status == .active { plan[other].status = .pending }
            plan[index].status = .active
        case "done", "drop":
            let status: PlanItem.Status = op == "done" ? .done : .dropped
            if let item {
                guard let index = find(item, in: plan) else { return fail(notFound(item, in: plan)) }
                plan[index].status = status
            } else {
                for index in plan.indices where plan[index].isOpen { plan[index].status = status }
            }
        case "view":
            return Outcome(plan: current, result: .done(summary(current)))
        default:
            return fail("op 只能是 init、start、done、drop、append、view")
        }
        normalize(&plan)
        return Outcome(plan: plan, result: .done(summary(plan)))
    }

    /// One step in progress: the first of several stays; with none, the first pending one starts (omp).
    static func normalize(_ plan: inout [PlanItem]) {
        var seen = false
        for index in plan.indices where plan[index].status == .active {
            if seen { plan[index].status = .pending }
            seen = true
        }
        if !seen, let first = plan.firstIndex(where: { $0.status == .pending }) { plan[first].status = .active }
    }

    /// What the model reads back: the list with its marks, and what is next.
    static func summary(_ plan: [PlanItem]) -> String {
        guard !plan.isEmpty else { return "计划是空的。" }
        let counted = plan.filter { $0.status != .dropped }
        var lines = ["计划（\(counted.filter { $0.status == .done }.count)/\(counted.count) 完成）："]
        for item in plan {
            let mark = switch item.status {
            case .pending: "[ ]"
            case .active: "[>]"
            case .done: "[x]"
            case .dropped: "[-]"
            }
            lines.append("\(mark) \(item.text)" + (item.byUser ? "（用户加的）" : ""))
        }
        if let active = plan.first(where: { $0.status == .active }) {
            lines.append("正在做：\(active.text)")
        } else if !plan.contains(where: \.isOpen) {
            lines.append("所有步骤都结束了。")
        }
        return lines.joined(separator: "\n")
    }

    private static func find(_ text: String, in plan: [PlanItem]) -> Int? {
        plan.firstIndex { $0.text == text }
            ?? plan.firstIndex { $0.text.compare(text, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }
    }

    private static func notFound(_ text: String, in plan: [PlanItem]) -> String {
        plan.isEmpty ? "计划还是空的，先用 init 列出步骤"
            : "计划里没有「\(text)」，要用步骤的原文：" + plan.map { "「\($0.text)」" }.joined(separator: "、")
    }
}
