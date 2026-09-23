import Foundation

/// A line the runner writes into the thread between turns (7g): whom a message went to, a hand-off, an autorun's
/// round, a goal's check, and how a chain or an autorun ended. Part of the history, unlike a command's one-off card
/// (spec §9.8c: 「轮次分隔必须写进 conv.messages」). The message carrying it is on the user's side; its text is what the
/// model reads (a hand-off's brief, a round's instruction), empty when the model needn't read anything.
struct ThreadEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// M1: the dispatcher's pick.
        case dispatch
        /// M2–M4: one member handed the work on.
        case handoff
        /// M4: a chain's end.
        case relayEnd
        /// A1–A2: a round begins.
        case round
        /// A3: another Agent checked the goal.
        case goalCheck
        /// A4: an autorun's end.
        case autorunEnd
        /// 8d, K14: `@`-ed on the canvas, Agents joined — a direct chat became a group in place, or a group grew.
        case upgrade
        /// 9e: Bob's arrangement of one message — who works together, who after whom. Never his reasons.
        case conduct
        /// 9e: an arrangement that ended before its last step — stopped, paused, or a step that didn't finish.
        case conductEnd
        /// 9e, E: a member's reply failed and another took its work over.
        case takeover
        /// 9e, D: Bob's conclusion from members who worked side by side — the one thing of his the user reads in full.
        case summary
        /// 10e: the user went back to a message and sent it again, changed — what it replaced is kept under this line.
        /// Empty text: the model reads nothing of it.
        case rewind
        /// User 2026-09-17: a note written to the memory, changed or forgotten — said in the thread, with 撤销.
        case memory
        /// User 2026-09-17: `/agent 目的` made a subagent (`passed`), or couldn't — said in the thread, so the canvas's
        /// window says it too.
        case subagent
        /// User 2026-09-23: `/skills`, `/mcp`, `/hooks` made a Skill, an MCP service or a Hook (`passed`), or couldn't.
        case created
    }

    /// Bob's arrangement (9e): the stages in order — the members of one stage start together, the next stage waits
    /// for them — and the background runs of the stages that had several.
    struct Arrangement: Codable, Equatable, Sendable {
        struct Lane: Codable, Equatable, Sendable {
            var agentID: UUID
            var subtaskID: UUID
        }

        /// The user's message it arranges.
        var messageID: UUID
        var stages: [[UUID]]
        var lanes: [Lane] = []

        func lane(of agentID: UUID) -> UUID? { lanes.first { $0.agentID == agentID }?.subtaskID }
    }

    var kind: Kind
    /// The line itself, names as they were then — a member may be renamed or deleted later.
    var title: String
    /// Under the line: the brief, the reason, the round's instruction, the check's reasons.
    var detail = ""
    /// Who takes over (handoff), who got it (dispatch), who checked (goalCheck), whose direct chat it was (upgrade).
    var agentID: UUID?
    /// A goal check that passed; `false` when it didn't.
    var passed: Bool?
    /// A goal check's subtask: its process can be opened (A3).
    var subtaskID: UUID?
    /// conduct and conductEnd: the arrangement (9e).
    var arrangement: Arrangement?
    /// takeover: whose work it was (9e, E).
    var from: UUID?
    /// rewind: the earlier version it stands for (10e).
    var versionID: UUID?
    /// memory: what was written, and what 撤销 puts back.
    var memoryChange: MemoryChange?
    /// memory: the user took it back.
    var undone: Bool?
}
