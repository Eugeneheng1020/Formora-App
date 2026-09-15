import SwiftUI

/// `/agent 目的` (user 2026-09-15): the model drafts a name, a line and a system prompt from the purpose; the user checks,
/// changes what they like, picks the tool tier and where it lives, and saves. Everything editable — the model's draft is
/// a start, not the last word.
struct SubagentDialog: View {
    let state: AppState

    var body: some View {
        if let draft = state.subagentDraft {
            let binding = Binding(get: { state.subagentDraft ?? draft }, set: { state.subagentDraft = $0 })
            MessagesDialog(kicker: "new subagent", title: "新建子代理", note: "按目的起草好了名字和提示词，改到满意再保存。保存后 /名字 任务 派活；Agent 也会按需要派它。",
                           identifier: "subagent", onClose: { state.subagentDraft = nil }) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        FormLabel(text: "目的")
                        Text(draft.purpose)
                            .font(FormoraFont.ui(12))
                            .foregroundStyle(Palette.inkMuted.color)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("subagent.purpose")
                    }
                    if draft.isGenerating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在按目的起草…").font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color)
                        }
                        .accessibilityIdentifier("subagent.generating")
                    }
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            FormLabel(text: "名字（也是命令：/名字）")
                            InputField(placeholder: "例如：探路", text: binding.name, isInvalid: draft.problem != nil, identifier: "subagent.name")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            FormLabel(text: "工具")
                            SegmentedControl(options: [(ToolTier.read, "只读"), (ToolTier.write, "可写"), (ToolTier.exec, "可执行命令")],
                                             selection: binding.tier, identifier: "subagent.tier")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            FormLabel(text: "存在哪")
                            SegmentedControl(options: [(SubagentLibrary.Scope.project, "本项目"), (SubagentLibrary.Scope.global, "全局")],
                                             selection: binding.scope, identifier: "subagent.scope")
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FormLabel(text: "一句话描述（Agent 靠它判断什么时候派）")
                        InputField(placeholder: "什么时候派它、它交回什么", text: binding.description, isInvalid: false, identifier: "subagent.description")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FormLabel(text: "系统提示词")
                        FormoraTextEditor(placeholder: "它是谁、做什么、怎么做、不做什么、报告怎么写", text: binding.prompt, height: 220,
                                          identifier: "subagent.prompt")
                    }
                    if let problem = draft.problem { InlineError(text: problem, identifier: "subagent.problem") }
                }
            } footer: {
                Button("取消") { state.subagentDraft = nil }.buttonStyle(FormoraButtonStyle(kind: .ghost))
                Button("重新起草") { state.regenerateSubagentDraft() }
                    .buttonStyle(FormoraButtonStyle(kind: .ghost))
                    .disabled(draft.isGenerating)
                    .accessibilityIdentifier("subagent.regenerate")
                Button("保存") { state.saveSubagentDraft() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .disabled(draft.isGenerating)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("subagent.save")
            }
        }
    }
}
