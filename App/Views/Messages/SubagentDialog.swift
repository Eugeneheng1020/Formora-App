import SwiftUI

/// 手填 / 编辑一个子代理的表单。`/agent 目的` 不再走这里——它由模型直接写好存好（user 2026-09-16）。这个弹窗只在两处出现：
/// 「设置 → 子代理 → 新建」空手创建，和「设置 → 子代理 → 编辑」改一个已有的；`/agent` 起草时若撞名或提示词空了，也退回到这里让用户改。
struct SubagentDialog: View {
    let state: AppState

    var body: some View {
        if let draft = state.subagentDraft {
            let binding = Binding(get: { state.subagentDraft ?? draft }, set: { state.subagentDraft = $0 })
            let editing = draft.isEditing
            MessagesDialog(kicker: editing ? "edit subagent" : "new subagent",
                           title: editing ? "编辑子代理" : "新建子代理",
                           note: editing ? "改到满意再保存。改名字等于改命令：/名字 任务。"
                                         : "填好保存。之后 /名字 任务 派活，Agent 也会按需要派它。想让 AI 起草，用消息里的 /agent 目的。",
                           identifier: "subagent", onClose: { state.subagentDraft = nil }) {
                VStack(alignment: .leading, spacing: 16) {
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
                Button("保存") { state.saveSubagentDraft() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("subagent.save")
            }
        }
    }
}
