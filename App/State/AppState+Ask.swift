import Foundation

/// Where a question with several parts stands (user 2026-09-15, 2026-09-23): the answers so far, an earlier part shown again,
/// and what was typed for each part — the composer shows it again when 上一步 comes back to that part.
struct AskProgress: Equatable {
    /// The `ask` call it belongs to: another question starts afresh.
    var callID: String
    var answered: [AskTool.Answer] = []
    var viewing: Int?
    /// The composer's words per part, typed or half-typed.
    var drafts: [Int: String] = [:]
}

extension AppState {
    /// The progress on the question waiting in this conversation — empty for a new one.
    func askState(_ id: UUID) -> AskProgress? {
        guard let pending = chat.pendingQuestion(id) else { return nil }
        if let progress = askProgress[id], progress.callID == pending.call.id { return progress }
        return AskProgress(callID: pending.call.id)
    }

    func askAnswered(_ id: UUID) -> [AskTool.Answer] { askState(id)?.answered ?? [] }

    func askNavigation(_ id: UUID, count: Int) -> AskNavigation {
        let progress = askState(id)
        return AskNavigation(count: count, answered: progress?.answered ?? [], viewing: progress?.viewing)
    }

    /// 上一步 / 下一步: the composer's words stay with the part they were typed for, and the part shown gets its own back.
    func moveAsk(_ id: UUID, count: Int, _ change: (inout AskNavigation) -> Void) {
        guard var progress = askState(id) else { return }
        var nav = askNavigation(id, count: count)
        let before = nav.index
        change(&nav)
        progress.drafts[before] = composerDrafts[id]?.text ?? ""
        progress.viewing = nav.viewing
        askProgress[id] = progress
        composerDrafts[id, default: ComposerDraft()].text = progress.drafts[nav.index] ?? ""
    }

    /// An answer for the part shown; `typed` is what the composer held. Returns every answer once the last part is answered
    /// — the caller hands them on — else `nil`, and the composer moves to the next part's words.
    func recordAsk(_ id: UUID, count: Int, _ answer: AskTool.Answer, typed: String? = nil) -> [AskTool.Answer]? {
        guard var progress = askState(id) else { return nil }
        var nav = askNavigation(id, count: count)
        let at = nav.index
        let finished = nav.record(answer)
        if finished {
            askProgress[id] = nil
            return nav.answered
        }
        progress.answered = nav.answered
        progress.viewing = nav.viewing
        if let typed { progress.drafts[at] = typed } else { progress.drafts[at] = nil }
        askProgress[id] = progress
        composerDrafts[id, default: ComposerDraft()].text = progress.drafts[nav.index] ?? ""
        return nil
    }

    /// Enter in the composer with a question of several parts waiting (user 2026-09-23): the words answer the part shown and
    /// the next part comes up, the composer cleared for it; only the last part's Enter sends. `false` = not taken here —
    /// one part, or the last one: sent as before, where the hooks see it.
    func typeAskAnswer(_ id: UUID, text: String) -> Bool {
        guard let pending = chat.pendingQuestion(id), pending.questions.count > 1 else { return false }
        let nav = askNavigation(id, count: pending.questions.count)
        // The last part still open, not an earlier one shown again: this Enter sends.
        if nav.viewing == nil, nav.answered.count == pending.questions.count - 1 { return false }
        _ = recordAsk(id, count: pending.questions.count, AskTool.Answer(typed: text), typed: text)
        return true
    }
}
