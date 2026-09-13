import AppKit
import SwiftUI

/// A conversation's avatar: the Agent's for a direct chat, the member grid for a group.
struct ConversationAvatar: View {
    let state: AppState
    let conversation: Conversation
    let size: CGFloat

    var body: some View {
        if conversation.isGroup {
            GroupAvatar(faces: ConversationReadiness.members(of: conversation, agents: state.agents).map {
                GroupAvatar.Face(image: state.agents.avatars[$0.id], initial: $0.role.initial)
            }, size: size)
        } else if let agent = state.agents.agent(conversation.agentID) {
            AgentAvatar(image: state.agents.avatars[agent.id], initial: agent.role.initial, size: size, isMuted: !agent.isActive)
        } else {
            AgentAvatar(image: nil, initial: "?", size: size, isMuted: true)
        }
    }
}

/// A group's avatar (C18, user 2026-09-08): a rounded square (D2) on a ground colour with the members laid out
/// like WeChat — up to nine, the first row taking the remainder so the grid stays centred.
struct GroupAvatar: View {
    struct Face {
        let image: NSImage?
        let initial: String
    }

    let faces: [Face]
    let size: CGFloat

    var body: some View {
        let shown = Array(faces.prefix(9))
        let columns = shown.count <= 1 ? 1 : shown.count <= 4 ? 2 : 3
        let padding = max(2, (size * 0.08).rounded())
        let gap = max(1, (size * 0.04).rounded())
        let cell = (size - padding * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        ZStack {
            AvatarShape().fill(Palette.surfaceRaised2.color)
            if shown.isEmpty {
                IconView(Icons.users, size: size * 0.45).foregroundStyle(Palette.inkMuted.color)
            } else {
                VStack(spacing: gap) {
                    ForEach(Array(Self.rows(count: shown.count, columns: columns).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: gap) {
                            ForEach(row, id: \.self) { index in tile(shown[index], side: cell) }
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(AvatarShape())
        .accessibilityHidden(true)
    }

    /// Indices per row; the first row holds what doesn't fill a whole row.
    static func rows(count: Int, columns: Int) -> [[Int]] {
        guard count > 0 else { return [] }
        let first = count % columns == 0 ? columns : count % columns
        var rows = [Array(0..<first)]
        var start = first
        while start < count {
            rows.append(Array(start..<min(start + columns, count)))
            start += columns
        }
        return rows
    }

    private func tile(_ face: Face, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
        return ZStack {
            if let image = face.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                shape.fill(Palette.accentSoft.color)
                Text(face.initial)
                    .font(FormoraFont.ui(max(7, side * 0.5), weight: 600))
                    .foregroundStyle(Palette.accent.color)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
    }
}

/// No conversation in this project (C20): the Agent empty page's pattern — a sketch of the list with the accent
/// `+`, and one sentence naming both ways in.
struct MessagesEmptyState: View {
    var body: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(Palette.surfaceRaised2.color).frame(width: 46, height: 8)
                    Spacer(minLength: 0)
                    IconView(Icons.plus, size: 11)
                        .foregroundStyle(Palette.accent.color)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Palette.accentSoft.color))
                        .overlay(Circle().strokeBorder(Palette.accent.color.opacity(0.6), lineWidth: 1))
                }
                Capsule().fill(Palette.surfaceRaised.color).frame(height: 18)
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(height: 38)
                }
            }
            .padding(14)
            .frame(width: 220)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("在 Agent 详情点「发起对话」开始单聊")
                Text("或点消息列表右上角的 + 建群聊")
            }
            .font(FormoraFont.ui(13))
            .foregroundStyle(Palette.inkMuted.color)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("messages.empty.text")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messages.empty")
    }
}
