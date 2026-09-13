import SwiftUI

/// Manage Projects (todo #7, user decision 2026-09-11): centered dialog; projects on the left; the
/// selected project's path and description on the right, both editable. A project's name is its
/// folder's name. Deleting removes it from Formora only — no file or folder is touched.
struct ManageProjectsDialog: View {
    let state: AppState
    let session: ProjectSession

    private enum SaveState { case clean, dirty, saved }

    @State private var selectedID: UUID?
    @State private var summaryDraft = ""
    @State private var saveState: SaveState = .clean
    @State private var saveTask: Task<Void, Never>?
    @State private var access: ProjectSession.Access = .none

    private var selected: ProjectRecord? {
        session.projects.first { $0.id == selectedID } ?? session.projects.first
    }

    var body: some View {
        ZStack {
            // Clicking the scrim does not close the dialog (design spec §7.2); Esc and ✕ do.
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            shell
        }
        .onAppear { select(session.current ?? session.projects.first) }
    }

    private var shell: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line.color).frame(height: 1)
            HStack(spacing: 0) {
                projectList.frame(width: 220)
                Rectangle().fill(Palette.line.color).frame(width: 1)
                // Scrolls once its rows outgrow the dialog (10g added one) — the header and the footer stay.
                ScrollView {
                    detail.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Palette.line.color).frame(height: 1)
            footer
        }
        .frame(width: 680, height: 540)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .modalShadow()
        .background {
            Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manage.dialog")
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("管理项目").font(FormoraFont.ui(18, weight: 700)).foregroundStyle(Palette.ink.color)
                Text("项目名称就是文件夹名称。可以修改路径和简介。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkMuted.color)
            }
            Spacer(minLength: 0)
            IconActionButton(icon: Icons.close, label: "关闭", identifier: "manage.close", action: close)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("删除只会从 Formora 中移除，不会删除任何文件或文件夹")
                .font(FormoraFont.ui(11.5))
                .foregroundStyle(Palette.inkFaint.color)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let selected {
                Button { reveal(selected) } label: {
                    Label { Text("在 Finder 中显示") } icon: { IconView(Icons.reveal, size: 14) }
                }
                .buttonStyle(FormoraButtonStyle())
                .disabled(!isAvailable)
                .accessibilityIdentifier("manage.reveal")

                Button { delete(selected) } label: {
                    Label { Text("删除") } icon: { IconView(Icons.trash, size: 14) }
                }
                // Destructive actions are entirely in the alert color (user 2026-09-11, rule R1).
                .buttonStyle(FormoraButtonStyle(kind: .destructive))
                .accessibilityIdentifier("manage.delete")

                if selected.id != session.current?.id {
                    Button("打开") { open(selected) }
                        .buttonStyle(FormoraButtonStyle(kind: .primary))
                        .accessibilityIdentifier("manage.open")
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
    }

    // MARK: List

    private var projectList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(session.projects) { project in
                    ManageRow(project: project,
                              isSelected: project.id == selected?.id,
                              isCurrent: project.id == session.current?.id) { select(project) }
                }
            }
            .padding(8)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manage.list")
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard let index = session.projects.firstIndex(where: { $0.id == selected?.id }) else { return .ignored }
        let next = min(max(index + delta, 0), session.projects.count - 1)
        select(session.projects[next])
        return .handled
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let selected {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    label("名称")
                    Text(selected.name)
                        .font(FormoraFont.mono(12))
                        .foregroundStyle(Palette.ink.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("manage.name")
                }
                GridRow {
                    label("路径")
                    HStack(spacing: 9) {
                        Text(PathText.abbreviate(selected.folderPath))
                            .font(FormoraFont.mono(12))
                            .foregroundStyle(Palette.ink.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("manage.path")
                        Spacer(minLength: 0)
                        Button("更改…") { relocate(selected) }
                            .buttonStyle(FormoraButtonStyle())
                            .accessibilityIdentifier("manage.relocate")
                    }
                }
                GridRow {
                    label("状态")
                    statusLine
                }
                GridRow(alignment: .top) {
                    label("简介").padding(.top, 10)
                    VStack(alignment: .trailing, spacing: 6) {
                        FormoraTextEditor(placeholder: "这个项目大概是做什么的", text: $summaryDraft, height: 116,
                                          metrics: .detail, identifier: "manage.summary")
                        Text(saveState == .dirty ? "有未保存修改" : saveState == .saved ? "已保存" : " ")
                            .font(FormoraFont.mono(10.5))
                            .foregroundStyle(saveState == .dirty ? Palette.ink.color : Palette.inkFaint.color)
                            .accessibilityIdentifier("manage.saveState")
                    }
                }
                // 10c: the instruction files every Agent here follows.
                GridRow(alignment: .top) {
                    label("说明文件")
                    instructionFiles
                }
                // 10g: the rules watched while a reply is written.
                GridRow(alignment: .top) {
                    label("盯住的规则")
                    watchedRules
                }
                // 10b: what this project no longer asks about — each one can go, here.
                GridRow(alignment: .top) {
                    label("不再询问")
                    RememberedRules(store: state.approvalRules, project: selected.id)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .onChange(of: summaryDraft) { _, text in scheduleSave(text, for: selected) }
        } else {
            Text("还没有项目")
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkFaint.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(FormoraFont.ui(11))
            .foregroundStyle(Palette.inkFaint.color)
            .frame(width: 120, alignment: .leading)
            .gridColumnAlignment(.leading)
    }

    @ViewBuilder private var statusLine: some View {
        switch access {
        case .available:
            StatusLine(text: "可用", tone: .success)
        case .unavailable(let reason):
            HStack(spacing: 9) {
                StatusLine(text: "不可用 · \(reason.message)", tone: .alert)
                Text("用「更改…」重新定位").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
            }
        case .none:
            StatusLine(text: "未检查")
        }
    }

    /// 10g: the rules watched while a reply is written, or how to have one.
    @ViewBuilder private var watchedRules: some View {
        let rules: [WatchRules.Rule] = if case .available(let root) = access { WatchRules.load(root: root) } else { [] }
        if rules.isEmpty {
            Text("没有。在项目的 .formora/rules/ 里放一个 .md 文件：开头写 condition（一个正则表达式），正文写规则。Agent 写出匹配的内容时会被当场打断，提醒后重来；平时不占对话。")
                .font(FormoraFont.ui(11.5))
                .foregroundStyle(Palette.inkFaint.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("manage.rules")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rules, id: \.name) { rule in
                    HStack(spacing: 8) {
                        Text(rule.name).font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                        Text(rule.conditions.joined(separator: "  "))
                            .font(FormoraFont.mono(11))
                            .foregroundStyle(Palette.inkFaint.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text("平时不占对话；Agent 写出匹配的内容时当场打断，提醒后重来，每个对话每条一次。")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("manage.rules")
        }
    }

    /// 10c: which files are in effect, or how to have one.
    @ViewBuilder private var instructionFiles: some View {
        let files: [ContextFiles.File] = if case .available(let root) = access { ContextFiles.load(root: root) } else { [] }
        if files.isEmpty {
            Text("没有。在项目文件夹里放一个 AGENTS.md（或 CLAUDE.md），写上项目的约定，每个 Agent 都会照着做。")
                .font(FormoraFont.ui(11.5))
                .foregroundStyle(Palette.inkFaint.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("manage.instructions")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(files.map(\.path).joined(separator: "、"))
                    .font(FormoraFont.mono(12))
                    .foregroundStyle(Palette.ink.color)
                Text("每个 Agent 每次回答前都会读，照着做。")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
            }
            .accessibilityIdentifier("manage.instructions")
        }
    }

    private var isAvailable: Bool {
        if case .available = access { return true }
        return false
    }

    // MARK: Actions

    private func select(_ project: ProjectRecord?) {
        selectedID = project?.id
        summaryDraft = project?.summary ?? ""
        saveState = .clean
        access = project.map { session.availability(of: $0) } ?? .none
    }

    private func scheduleSave(_ text: String, for record: ProjectRecord) {
        guard text != record.summary else { return }
        saveState = .dirty
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            session.updateSummary(record, to: text)
            saveState = .saved
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, saveState == .saved { saveState = .clean }
        }
    }

    private func relocate(_ record: ProjectRecord) {
        switch session.relocate(record) {
        case .cancelled:
            break
        case .moved:
            select(record)
            state.toasts.show("已改为「\(record.name)」", note: PathText.abbreviate(record.folderPath))
        case .failed(let message):
            state.toasts.show("没有更改路径", note: message, isError: true)
        }
    }

    private func reveal(_ record: ProjectRecord) {
        if !session.revealInFinder(record) {
            state.toasts.show("无法在 Finder 中显示", note: "文件夹当前不可用", isError: true)
        }
    }

    private func delete(_ record: ProjectRecord) {
        let name = record.name
        let index = session.projects.firstIndex { $0.id == record.id } ?? 0
        state.approvalRules.removeAll(project: record.id)
        session.remove(record)
        state.toasts.show("已从 Formora 中移除「\(name)」", note: "文件夹没有被删除")
        if session.projects.isEmpty {
            close()
        } else {
            select(session.projects[min(index, session.projects.count - 1)])
        }
    }

    private func open(_ record: ProjectRecord) {
        session.open(record)
        close()
    }

    private func close() {
        saveTask?.cancel()
        if let selected, summaryDraft != selected.summary { session.updateSummary(selected, to: summaryDraft) }
        state.isManagingProjects = false
    }
}

/// 10b: the steps this project no longer asks about (spec §8.7 rule 1: what can be added can be removed, in one place).
private struct RememberedRules: View {
    let store: ApprovalRuleStore
    let project: UUID

    var body: some View {
        let rules = store.rules(for: project)
        VStack(alignment: .leading, spacing: 7) {
            if rules.isEmpty {
                Text("还没有。确认卡片上点「以后这个项目里都不再问」，会记在这里。")
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(rules) { rule in
                    HStack(spacing: 10) {
                        Text(ApprovalGrants.label(rule))
                            .font(FormoraFont.ui(12))
                            .foregroundStyle(Palette.ink.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        // Destructive: the alert colour (rule R1).
                        Button("移除") { store.remove(rule, project: project) }
                            .buttonStyle(.plain)
                            .font(FormoraFont.ui(11.5))
                            .foregroundStyle(Palette.alert.color)
                            .accessibilityIdentifier("manage.rule.remove")
                    }
                }
                Text("对这个项目里的每个 Agent 都有效。")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manage.rules")
    }
}

private struct ManageRow: View {
    let project: ProjectRecord
    let isSelected: Bool
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isCurrent ? Palette.accent.color : Palette.inkFaint.color)
                    .frame(width: 5, height: 5)
                Text(project.name)
                    .font(FormoraFont.mono(12))
                    .foregroundStyle(isSelected ? Palette.ink.color : Palette.inkMuted.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isCurrent {
                    Text("当前")
                        .font(FormoraFont.mono(10))
                        .foregroundStyle(Palette.accent.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.accentSoft.color))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Palette.surfaceRaised2.color : isHovering ? Palette.surfaceRaised.color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Palette.lineStrong.color : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("manage.row.\(project.name)")
    }
}
