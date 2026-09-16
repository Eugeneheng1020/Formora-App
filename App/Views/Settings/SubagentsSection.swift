import AppKit
import SwiftUI

/// 设置 → 子代理 (user 2026-09-16): every subagent in one place — the ones Formora keeps (本项目 / 全局 / 内置)
/// and the ones the user wrote for Claude Code (`.claude/agents`, read here but managed there). Formora's own can be
/// edited (opens the creation dialog pre-filled) or deleted; the list is read again whenever it shows, so a file
/// changed in Finder appears. 新建 opens a blank creation; `/agent 目的` in 消息 fills one in from a purpose.
struct SubagentsSection: View {
    let state: AppState
    let session: ProjectSession

    private var library: SubagentLibrary { state.subagents }

    /// The groups in reading order; empty groups are dropped.
    private var groups: [(title: String, hint: String, items: [SubagentDefinition])] {
        let all = library.definitions
        return [
            ("本项目", ".formora/agents", all.filter { $0.source == .project }),
            ("全局", "~/.formora/agents", all.filter { $0.source == .global }),
            ("内置", "Formora 自带", all.filter { $0.source == .builtIn }),
            ("Claude Code", ".claude/agents · 在 Claude Code 里管理", all.filter { $0.source == .claude }),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .subagents, note: note) {
                Button("新建") { state.startBlankSubagentDraft() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .accessibilityIdentifier("subagents.new")
            }
            if library.definitions.isEmpty {
                Text("还没有子代理。在消息里用 /agent 目的 让 Agent 起草一个，或点右上角新建自己填。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .accessibilityIdentifier("subagents.empty")
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            SubagentGroupLabel(title: group.title, hint: group.hint)
                            VStack(spacing: 0) {
                                ForEach(group.items) { definition in
                                    SubagentRow(state: state, definition: definition)
                                }
                            }
                            .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                        }
                    }
                }
                .padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("subagents.list")
            }
        }
        .onAppear { library.reload(projectRoot: session.accessibleRoot) }
    }

    private var note: String {
        let managed = library.definitions.filter { $0.source != .claude }.count
        let claude = library.definitions.count - managed
        if claude > 0 { return "\(managed) 个由 Formora 管理 · \(claude) 个来自 Claude Code" }
        return "\(managed) 个 · /名字 任务 派活，Agent 也会按需要派"
    }
}

/// A group heading: 本项目 / 全局 / 内置 / Claude Code, with where its files live.
private struct SubagentGroupLabel: View {
    let title: String
    let hint: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(FormoraFont.mono(11, weight: 700))
                .foregroundStyle(Palette.inkMuted.color)
            Text(hint)
                .font(FormoraFont.ui(10.5))
                .foregroundStyle(Palette.inkFaint.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.bottom, 8)
    }
}

/// One subagent: its mark, name + description, its tier tag, then edit / delete — or, for a Claude Code file, a tag
/// saying it is managed there.
private struct SubagentRow: View {
    let state: AppState
    let definition: SubagentDefinition

    private var managed: Bool { definition.source != .claude }

    var body: some View {
        HStack(spacing: 11) {
            CapabilityMark(text: mark)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(definition.name)
                        .font(FormoraFont.ui(13, weight: 600))
                        .foregroundStyle(Palette.ink.color)
                    SmallTag(text: AppState.tierLabel(definition.tier))
                    if definition.model != nil { SmallTag(text: "指定模型", accent: true) }
                }
                Text(definition.description.isEmpty ? "（没有描述）" : definition.description)
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(definition.description.isEmpty ? Palette.inkFaint.color : Palette.inkMuted.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if managed {
                HStack(spacing: 8) {
                    IconActionButton(icon: Icons.pencil, label: "编辑 \(definition.name)",
                                     identifier: "subagents.edit.\(definition.name)") {
                        state.beginEditingSubagent(definition)
                    }
                    IconActionButton(icon: Icons.trash, label: "删除 \(definition.name)",
                                     identifier: "subagents.delete.\(definition.name)") {
                        state.subagentToDelete = definition
                    }
                }
            } else {
                SmallTag(text: "Claude Code")
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagents.row.\(definition.name)")
    }

    /// The mark: the first two characters of the name (a Chinese name shows its first two glyphs).
    private var mark: String { String(definition.name.prefix(2)) }

}
