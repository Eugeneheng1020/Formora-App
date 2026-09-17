import SwiftUI

/// 概览: the identity form (avatar, role, name, subtitle, status), auto-saved (spec §8.1), and 删除 Agent
/// (user 2026-09-08). The stats strip arrives with Skills and MCP (phase 5b).
struct AgentOverviewTab: View {
    let state: AppState
    let agent: AgentRecord

    @State private var name = ""
    @State private var subtitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailBlock(title: "身份信息", note: "角色创建后不能改，其他字段自动保存。") {
                BlockMeta(text: "自动保存")
            } content: {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        FormLabelCell(text: "头像")
                        HStack(spacing: 10) {
                            AgentAvatar(image: state.agents.avatars[agent.id], initial: agent.role.initial, size: 56)
                            CircleIconButton(icon: Icons.upload, label: "更换头像图片", identifier: "agent.avatarUpload", action: pickAvatar)
                        }
                    }
                    GridRow {
                        FormLabelCell(text: "角色")
                        Text(agent.role.name).font(FormoraFont.ui(12)).foregroundStyle(Palette.ink.color)
                    }
                    GridRow {
                        FormLabelCell(text: "名称")
                        InputField(placeholder: "名称", text: $name, identifier: "agent.name", onCommit: commitName)
                    }
                    GridRow {
                        FormLabelCell(text: "副标题")
                        InputField(placeholder: agent.role.summary, text: $subtitle, identifier: "agent.subtitle", onCommit: commitSubtitle)
                            .onChange(of: subtitle) { old, new in
                                if AgentStore.acceptSubtitle(new) == nil { subtitle = old }
                            }
                    }
                    GridRow {
                        FormLabelCell(text: "状态")
                        HStack(spacing: 10) {
                            FormoraSwitch(isOn: Binding(get: { agent.isActive },
                                                        set: { AgentActions.setActive(agent, $0, state: state) }),
                                          label: "激活", identifier: "agent.active")
                            Text(agent.isActive ? "已激活" : "已停用").font(FormoraFont.ui(12)).foregroundStyle(Palette.ink.color)
                        }
                    }
                }
            }
            DetailBlock(title: "删除 Agent", note: "删除后这个 Agent 的名称、头像和模型配置会一起移除，不能恢复。", isLast: true) {
                CircleIconButton(icon: Icons.trash, label: "删除这个 Agent", identifier: "agent.delete", isDestructive: true) {
                    state.agentToDelete = agent.id
                }
            } content: {
                EmptyView()
            }
        }
        .onAppear {
            name = agent.customName
            subtitle = agent.subtitle
        }
    }

    private func commitName() {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != agent.customName else { return }
        do {
            try state.agents.rename(agent, to: name)
            name = agent.customName
            state.toasts.show("已保存", note: "Agent 名称已更新", seconds: 2)
        } catch {
            name = agent.customName
            state.toasts.show("名称未保存", note: (error as? AgentProblem)?.message ?? error.localizedDescription, isError: true)
        }
    }

    private func commitSubtitle() {
        let final = AgentStore.finalSubtitle(subtitle, role: agent.role)
        guard final != agent.subtitle else {
            subtitle = agent.subtitle
            return
        }
        try? state.agents.setSubtitle(agent, to: subtitle)
        subtitle = agent.subtitle
        state.toasts.show("已保存", note: "副标题已更新", seconds: 2)
    }

    private func pickAvatar() {
        guard let url = pickAvatarImage() else { return }
        do {
            try state.agents.setAvatar(agent, from: url)
            state.toasts.show("已保存", note: "头像已更新", seconds: 2)
        } catch {
            state.toasts.show("头像未保存", note: (error as? AvatarImage.Problem)?.message ?? error.localizedDescription, isError: true)
        }
    }
}
