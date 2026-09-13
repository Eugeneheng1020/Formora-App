import SwiftUI

/// ⊕'s dialog (C6, C7). Never disabled at the button: with fewer than two usable Agents it opens anyway and
/// says why, Agent by Agent, with the way out (spec §9.2).
struct GroupCreateDialog: View {
    let state: AppState
    let session: ProjectSession

    @State private var name = ""
    @State private var members: [UUID] = []
    @State private var problem: String?

    var body: some View {
        let rows = state.agents.agents.map { MemberRowData(agent: $0, reason: reason($0)) }
        let usable = rows.filter { $0.reason == nil }.count
        if usable < 2 {
            MessagesDialog(kicker: "new group", title: "还不能建群聊", note: "群聊至少需要 2 个可用的 Agent。",
                           identifier: "groupCreate", onClose: close) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("当前只有 \(usable) 个可用 Agent。\nAgent 需要同时满足：已激活、拥有当前项目权限、主模型可用。")
                        .font(FormoraFont.ui(12))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("groupCreate.shortage")
                    let blocked = rows.filter { $0.reason != nil }
                    if !blocked.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(blocked, id: \.agent.id) { row in MemberRow(state: state, data: row, check: nil) }
                        }
                        .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    }
                }
            } footer: {
                Button("知道了", action: close).buttonStyle(FormoraButtonStyle(kind: .ghost))
                Button("去 Agent") {
                    close()
                    state.requestSection(.agents)
                }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .accessibilityIdentifier("groupCreate.gotoAgents")
            }
        } else {
            MessagesDialog(kicker: "new group", title: "新建群聊", note: "勾选参与的角色并起个名字。群里由你 @ 谁，谁才接活。",
                           identifier: "groupCreate", onClose: close) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("群聊名称").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color)
                        InputField(placeholder: "例如：购物车挽回专项", text: $name, isInvalid: problem != nil, identifier: "groupCreate.name")
                        if let problem { InlineError(text: problem, identifier: "groupCreate.problem") }
                    }
                    MemberList(count: members.count) {
                        ForEach(rows, id: \.agent.id) { row in
                            MemberRow(state: state, data: row, check: members.contains(row.agent.id)) { toggle(row.agent.id) }
                        }
                    }
                }
            } footer: {
                Button("取消", action: close).buttonStyle(FormoraButtonStyle(kind: .ghost))
                Button("创建群聊") { create() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("groupCreate.create")
            }
            .onChange(of: name) { problem = nil }
        }
    }

    private func reason(_ agent: AgentRecord) -> String? {
        AgentReadiness.blockReason(of: agent, currentProject: session.current, providers: state.providers)
    }

    private func toggle(_ id: UUID) {
        if let index = members.firstIndex(of: id) { members.remove(at: index) } else { members.append(id) }
        problem = nil
    }

    private func create() {
        guard let project = session.current else { return }
        do {
            let group = try state.conversations.createGroup(name: name, memberIDs: members, projectID: project.id) { id in
                state.agents.agent(id).flatMap(reason)
            }
            close()
            state.openConversation(group.id)
        } catch {
            problem = (error as? ConversationProblem)?.message ?? error.localizedDescription
        }
    }

    private func close() { state.groupDialog = nil }
}

/// 群设置 (C8, user 2026-09-07): the group's name, who is in it, and who is muted inside it. Explicit save.
struct GroupSettingsDialog: View {
    let state: AppState
    let session: ProjectSession
    let conversationID: UUID

    @State private var name = ""
    @State private var members: [GroupMember] = []
    @State private var problem: String?

    var body: some View {
        let rows = state.agents.agents.map { MemberRowData(agent: $0, reason: reason($0)) }
        let original = Set(state.conversations.conversation(conversationID)?.members.map(\.agentID) ?? [])
        MessagesDialog(kicker: "group", title: "群设置", note: "群名是这个会话的稳定标识，不会跟着任务名变。停用的成员留在群里，但不能被 @。",
                       identifier: "groupSettings", onClose: close) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("群聊名称").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color)
                    InputField(placeholder: "群聊名称", text: $name, isInvalid: problem != nil, identifier: "groupSettings.name")
                    if let problem { InlineError(text: problem, identifier: "groupSettings.problem") }
                }
                MemberList(count: members.count) {
                    ForEach(rows, id: \.agent.id) { row in
                        let index = members.firstIndex { $0.agentID == row.agent.id }
                        // An Agent already in the group may stay even when it can't work right now.
                        let data = original.contains(row.agent.id) ? MemberRowData(agent: row.agent, reason: nil, note: row.reason) : row
                        MemberRow(state: state, data: data, check: index != nil) { toggle(row.agent.id) } trailing: {
                            if let index {
                                FormoraSwitch(isOn: Binding(get: { !members[index].isMuted }, set: { members[index].isMuted = !$0 }),
                                              label: "在群里启用 \(row.agent.displayName)", identifier: "groupSettings.enabled.\(row.agent.customName)")
                            }
                        }
                    }
                }
            }
        } footer: {
            Button("取消", action: close).buttonStyle(FormoraButtonStyle(kind: .ghost))
            Button("保存") { save() }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("groupSettings.save")
        }
        .onAppear {
            guard let conversation = state.conversations.conversation(conversationID) else { return }
            name = conversation.groupName
            members = conversation.members
        }
        .onChange(of: name) { problem = nil }
    }

    private func reason(_ agent: AgentRecord) -> String? {
        AgentReadiness.blockReason(of: agent, currentProject: session.current, providers: state.providers)
    }

    private func toggle(_ id: UUID) {
        if let index = members.firstIndex(where: { $0.agentID == id }) { members.remove(at: index) } else { members.append(GroupMember(agentID: id)) }
        problem = nil
    }

    private func save() {
        do {
            try state.conversations.updateGroup(conversationID, name: name, members: members) { id in
                state.agents.agent(id).flatMap(reason)
            }
            close()
            state.toasts.show("群设置已保存", seconds: 2)
        } catch {
            problem = (error as? ConversationProblem)?.message ?? error.localizedDescription
        }
    }

    private func close() { state.groupDialog = nil }
}

private struct MemberRowData {
    let agent: AgentRecord
    /// Why it can't be picked (greyed).
    let reason: String?
    /// Shown like a reason but doesn't block (a member who can't work right now).
    var note: String?
}

/// 「参与角色」 + `N / 至少 2`, then the rows with a rule on top.
private struct MemberList<Rows: View>: View {
    let count: Int
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("参与角色").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color)
                Spacer(minLength: 0)
                BlockMeta(text: "\(count) / 至少 2").accessibilityIdentifier("group.memberCount")
            }
            ScrollView {
                VStack(spacing: 0) { rows() }
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `.project-permission-row.group-member-row`: a check (a choice, not a switch — spec §9.2), the avatar, the
/// name with the role or the reason it can't be picked.
private struct MemberRow<Trailing: View>: View {
    let state: AppState
    let data: MemberRowData
    /// `nil` hides the check (the shortage list only explains).
    let check: Bool?
    var toggle: () -> Void = {}
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let disabled = data.reason != nil
        HStack(spacing: 11) {
            Button(action: toggle) {
                HStack(spacing: 11) {
                    if let check { CheckBox(isOn: check) }
                    AgentAvatar(image: state.agents.avatars[data.agent.id], initial: data.agent.role.initial, size: 40, isMuted: disabled)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(data.agent.displayName)
                            .font(FormoraFont.ui(12.5, weight: 600))
                            .foregroundStyle(disabled ? Palette.inkFaint.color : Palette.ink.color)
                            .lineLimit(1)
                        Text(data.reason ?? data.note ?? data.agent.role.name)
                            .font(FormoraFont.ui(11))
                            .foregroundStyle(data.reason ?? data.note == nil ? Palette.inkMuted.color : Palette.inkFaint.color)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled || check == nil)
            trailing()
        }
        .padding(.vertical, 6)
        .frame(minHeight: 53)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("group.member.\(data.agent.customName)")
    }
}

extension MemberRow where Trailing == EmptyView {
    init(state: AppState, data: MemberRowData, check: Bool?, toggle: @escaping () -> Void = {}) {
        self.init(state: state, data: data, check: check, toggle: toggle, trailing: { EmptyView() })
    }
}

/// The dialogs of 消息: kicker, title, what it does, ✕; the body; the actions. The scrim doesn't close it;
/// Esc and ✕ do.
struct MessagesDialog<Content: View, Footer: View>: View {
    let kicker: String
    let title: String
    let note: String
    let identifier: String
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ZStack {
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(kicker.uppercased()).font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
                        Text(title).font(FormoraFont.ui(18, weight: 700)).foregroundStyle(Palette.ink.color)
                            .accessibilityIdentifier("\(identifier).title")
                        Text(note).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    IconActionButton(icon: Icons.close, label: "关闭", identifier: "\(identifier).close", action: onClose)
                }
                .padding(.top, 22)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                Rectangle().fill(Palette.line.color).frame(height: 1)
                content()
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
                Rectangle().fill(Palette.line.color).frame(height: 1)
                HStack(spacing: 9) {
                    Spacer(minLength: 0)
                    footer()
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
            }
            .frame(width: 560) // `.modal-shell.compact`
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .modalShadow()
            .background {
                Button("") { onClose() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }
}
