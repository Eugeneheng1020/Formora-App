import AppKit
import SwiftUI

/// 设置 → Skills: the global library (spec §8.2). Import a folder, or open the library folder in Finder; Skills
/// aren't edited here (user 2026-09-11), and the list is read again whenever it shows, so changes made in Finder
/// appear. Uninstalling waits until no Agent enables it and always asks first (it can't be undone cheaply).
struct SkillsSection: View {
    let state: AppState

    private var library: SkillLibrary { state.skills }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .skills, note: note) {
                Button("在 Finder 中打开") {
                    if let folder = library.revealDirectory() { NSWorkspace.shared.open(folder) }
                }
                .buttonStyle(FormoraButtonStyle())
                .help("Formora 存放 Skills 的文件夹")
                .accessibilityIdentifier("skills.openFolder")
                Button("导入文件夹") { SkillImport.run(state: state, enableFor: nil) }
                    .buttonStyle(FormoraButtonStyle())
                    .accessibilityIdentifier("skills.import")
            }
            if library.skills.isEmpty {
                Text("还没有安装 Skill。导入一个包含 SKILL.md 的文件夹即可。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            } else {
                VStack(spacing: 0) {
                    ForEach(library.skills) { skill in SkillLibraryRow(state: state, skill: skill) }
                }
                .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("skills.list")
            }
        }
        .onAppear { library.reload() }
    }

    private var note: String {
        "\(library.skills.count) 个已安装 · 安装一次，各 Agent 独立启用。"
    }
}

/// `.capability-row` without the tags (user 2026-09-11): the mark (back, user 2026-09-12), name + description, then the
/// icon buttons.
private struct SkillLibraryRow: View {
    let state: AppState
    let skill: Skill

    var body: some View {
        let users = state.skills.usage(skill.id)
        HStack(spacing: 11) {
            CapabilityMark(text: skill.mark)
            SkillSummary(skill: skill)
            HStack(spacing: 8) {
                IconActionButton(icon: Icons.trash, label: users > 0 ? SkillProblem.inUse(users).message : "卸载 \(skill.name)",
                                 identifier: "skills.uninstall.\(skill.id)") {
                    state.skillToUninstall = skill.id
                }
                .disabled(users > 0)
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.row.\(skill.id)")
    }
}

/// A Skill as its SKILL.md header describes it: the name, and when to use it.
struct SkillSummary: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(skill.name).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
            if !skill.document.description.isEmpty {
                Text(skill.document.description)
                    .font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Skill {
    /// Its `.capability-mark`: the name's first two characters, as an MCP server's — 「写 Skill」 gives 「写」, not 「写 」.
    var mark: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(2)).trimmingCharacters(in: .whitespaces).uppercased()
    }
}

/// `.capability-mark`: 32pt tile with the first two characters.
struct CapabilityMark: View {
    let text: String
    /// A brand's logo, single colour, in place of the letters (D94).
    var icon: SVGIcon? = nil

    var body: some View {
        Group {
            if let icon {
                IconView(icon, size: 16)
            } else {
                Text(text)
                    .font(FormoraFont.mono(10, weight: 700))
                    .lineLimit(1)
            }
        }
            .foregroundStyle(Palette.inkMuted.color)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
            .frame(width: 36, alignment: .leading)
    }
}

/// `.source-tag` / `.scope-tag`: 20pt pill, mono 10.
struct SmallTag: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text)
            .font(FormoraFont.mono(10))
            .foregroundStyle(accent ? Palette.accent.color : Palette.inkMuted.color)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .frame(minHeight: 20)
            .background(Capsule().fill(accent ? Palette.accentSoft.color : Palette.surfaceRaised2.color))
    }
}

/// Importing a Skill folder from 设置 or from an Agent's Skills tab; from an Agent it is enabled for that
/// Agent only (spec §8.2).
@MainActor
enum SkillImport {
    static func run(state: AppState, enableFor agent: AgentRecord?) {
        let panel = NSOpenPanel()
        panel.title = "选择 Skill 文件夹"
        panel.message = "文件夹里需要有一份 SKILL.md"
        panel.prompt = "导入"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFolder(url, state: state, enableFor: agent)
    }

    static func importFolder(_ url: URL, state: AppState, enableFor agent: AgentRecord?) {
        do {
            let skill = try state.skills.importFolder(url)
            if let agent { try? state.agents.setSkill(agent, skill.id, enabled: true) }
            state.toasts.show("已导入「\(skill.name)」",
                              note: agent.map { "已为 \($0.displayName) 启用" } ?? "在 Agent 的 Skills 标签里启用后生效")
        } catch {
            state.toasts.show("没有导入", note: (error as? SkillProblem)?.message ?? error.localizedDescription, isError: true)
        }
    }
}
