import SwiftUI

/// 设置 → 归档 (C16): the last step of a conversation's visibility, and the only place to delete one
/// (spec §9.1b). Rows keep the capability rows' rhythm; every project's archived conversations are here.
struct ArchiveSection: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        let list = state.conversations.archived()
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .archive, note: "归档的对话不在消息列表里，这里能恢复或删除。") { EmptyView() }
            if list.isEmpty {
                Text("还没有归档的会话；在消息列表里右键一条，选「归档会话」。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .accessibilityIdentifier("archive.empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(list) { conversation in row(conversation) }
                }
                .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("archive.list")
            }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        let who = conversation.isGroup
            ? "\(conversation.groupName) · \(conversation.members.count) 个成员"
            : ConversationReadiness.headline(of: conversation, agents: state.agents)
        let project = session.projects.first { $0.id == conversation.projectID }?.name ?? "已移除的项目"
        return HStack(spacing: 11) {
            ConversationAvatar(state: state, conversation: conversation, size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text(conversation.title).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color).lineLimit(1)
                Text(who).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color).lineLimit(1).padding(.top, 2)
                HStack(spacing: 6) {
                    SmallTag(text: project)
                    SmallTag(text: "\(conversation.messages.count) 条消息")
                    SmallTag(text: conversation.status.label)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("恢复") { restore(conversation) }
                .buttonStyle(FormoraButtonStyle())
                .accessibilityIdentifier("archive.restore.\(conversation.title)")
            CircleIconButton(icon: Icons.trash, label: "删除「\(conversation.title)」", identifier: "archive.delete.\(conversation.title)",
                             isDestructive: true) { state.conversationToDelete = conversation.id }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }

    private func restore(_ conversation: Conversation) {
        state.conversations.setVisibility(conversation.id, .normal)
        state.toasts.show("已恢复", note: "「\(conversation.title)」回到了消息列表", seconds: 2)
    }
}
