import Foundation

/// The lines a run writes when it stops and waits for the user (user 2026-09-20, 行为评估设计 §5). The behaviour
/// evaluation counts them (「它问了你几次」) and learns from 等你回答 that a turn ended on a question; a real
/// diagnosis reads them to see why a run stood still. Names and statuses only — never arguments or a reply.
enum WaitLog {
    static let category = "wait"

    private static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    static func waitingForApproval(call: ToolCall, conversation id: UUID) -> String {
        "等你确认 \(call.name) 对话=\(short(id)) \(call.summary)"
    }

    static func decided(call: ToolCall, conversation id: UUID, allowed: Bool) -> String {
        "\(allowed ? "允许" : "拒绝") \(call.name) 对话=\(short(id))"
    }

    static func waitingForAnswer(conversation id: UUID) -> String {
        "等你回答 对话=\(short(id))"
    }
}
