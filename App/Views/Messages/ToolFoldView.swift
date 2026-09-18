import SwiftUI

/// 消息里的工具执行折叠 (user 2026-09-15; spec §6.2): the run's steps under its words. Closed, one line — 「工具 · 8 步 · 完成 7 ·
/// 失败 1」 — and, while the run is live, the step in hand under it; open, every card in order.
struct ToolFoldView: View {
    let steps: [ToolFold.Step]
    let isRunning: Bool
    /// The call executing right now, and the one waiting for the user.
    let executing: String?
    let approval: String?
    let phase: (ToolFold.Step) -> ToolCallCard.Phase
    /// Opened at the thread's end, the cards would land under the composer: the thread brings the group into view.
    var reveal: (AnyHashable) -> Void = { _ in }
    /// The cards' copy icon before a command (user 2026-09-15).
    var onCopy: ((String) -> Void)? = nil

    @State private var isOpen = VerificationHooks.opensToolCards

    private var anchor: String { "tools.fold." + (steps.first?.messageID.uuidString ?? "") }

    var body: some View {
        let summary = ToolFold.summary(steps, isRunning: isRunning, approval: approval)
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FoldHeader(icon: Icons.chip, summary: summary, isOpen: isOpen, identifier: "tools.fold.toggle") {
                    isOpen.toggle()
                    if isOpen {
                        let anchor = anchor
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            reveal(anchor)
                        }
                    }
                }
                if isOpen {
                    ForEach(steps) { step in ToolCallCard(call: step.call, phase: phase(step), onCopy: onCopy) }
                } else if let live = ToolFold.live(steps, executing: executing, approval: approval) {
                    ToolCallCard(call: live.call, phase: phase(live), onCopy: onCopy)
                }
            }
            .id(anchor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tools.fold")
        }
    }
}
