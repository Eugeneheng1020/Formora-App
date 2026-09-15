import Foundation

/// 消息里的工具执行折叠 (user 2026-09-15): one run's tool calls in one group under the run's words — closed, one line and
/// the step in hand; open, every card. Pure: the view reads it, the tests check it.
enum ToolFold {
    struct Step: Identifiable, Equatable, Sendable {
        let messageID: UUID
        let call: ToolCall

        var id: String { call.id }
    }

    /// Counts of what happened to the steps: `open` ones have no result yet.
    struct Counts: Equatable, Sendable {
        var done = 0
        var failed = 0
        var denied = 0
        var stopped = 0
        var open = 0

        var total: Int { done + failed + denied + stopped + open }
    }

    /// Calls that keep their own place: the plan is docked above the composer (D4), a question is its own card (D6), a
    /// delegation is the helper's strip (S8).
    static let apart: Set<String> = [PlanTool.spec.name, AskTool.spec.name, TeamTools.delegateName]

    /// Every turn's calls, in order.
    static func steps(in messages: [Message]) -> [Step] {
        messages.flatMap { message in
            message.toolCalls.filter { !apart.contains($0.name) }.map { Step(messageID: message.id, call: $0) }
        }
    }

    static func counts(_ steps: [Step]) -> Counts {
        var counts = Counts()
        for step in steps {
            switch step.call.result?.status {
            case .done: counts.done += 1
            case .failed: counts.failed += 1
            case .denied: counts.denied += 1
            case .stopped: counts.stopped += 1
            case nil: counts.open += 1
            }
        }
        return counts
    }

    /// The closed group's one line: 「工具 · 8 步 · 完成 7 · 失败 1」; a step waiting for the user says 等你确认, a live run's
    /// other open steps 进行中, a finished run's never ran. Empty with no steps: the view shows nothing.
    static func summary(_ steps: [Step], isRunning: Bool, approval: String? = nil) -> String {
        let counts = counts(steps)
        guard counts.total > 0 else { return "" }
        var parts = ["工具", "\(counts.total) 步"]
        if counts.done > 0 { parts.append("完成 \(counts.done)") }
        if counts.failed > 0 { parts.append("失败 \(counts.failed)") }
        if counts.denied > 0 { parts.append("已拒绝 \(counts.denied)") }
        if counts.stopped > 0 { parts.append("已停止 \(counts.stopped)") }
        if counts.open > 0 {
            if let approval, steps.contains(where: { $0.id == approval && $0.call.result == nil }) {
                parts.append("等你确认")
            } else {
                parts.append(isRunning ? "进行中" : "没有执行 \(counts.open)")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The step in hand while the run is live — the one waiting for the user before the one executing — shown under the
    /// closed group's line. `nil` once every step has its result, or when the ids belong to another run.
    static func live(_ steps: [Step], executing: String?, approval: String?) -> Step? {
        if let approval, let step = steps.first(where: { $0.id == approval && $0.call.result == nil }) { return step }
        if let executing, let step = steps.first(where: { $0.id == executing && $0.call.result == nil }) { return step }
        return nil
    }
}
