import SwiftUI

/// `/agent 目的` 由模型直接写好存好（user 2026-09-16），平时用不到这个弹窗；只有它起的名字撞了车、不是英文，或者提示词是空的，
/// 才退到这里，字段都填好，让用户改一下再存。「设置 → SubAgent」只看、只删，不从这里新建或编辑（user 2026-09-17）。
struct SubagentDialog: View {
    let state: AppState

    var body: some View {
        if let draft = state.subagentDraft {
            let binding = Binding(get: { state.subagentDraft ?? draft }, set: { state.subagentDraft = $0 })
            MessagesDialog(kicker: "new subagent", title: "新建子代理", note: "改好再保存；之后用 /名字 任务 派活。",
                           identifier: "subagent", onClose: { state.subagentDraft = nil }) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            FormLabel(text: "名字（英文，也是命令：/名字）")
                            InputField(placeholder: "例如：code-reviewer", text: binding.name, isInvalid: draft.problem != nil, identifier: "subagent.name")
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
                        FormLabel(text: "中文简介（Agent 靠它判断什么时候派）")
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
