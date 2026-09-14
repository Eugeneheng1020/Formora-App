import AppKit
import SwiftUI

/// 一键提交 (user 2026-09-14): the changed files ticked, each one's diff, the message (the model can draft it), and three
/// ways out — 提交, 提交并推送, 提交并发 PR. On the main branch the work goes to a branch of its own first.
struct CommitSheet: View {
    let state: AppState
    let root: URL

    @State private var flow: CommitFlow
    @State private var shown: GitChange?
    @State private var diff = ""

    init(state: AppState, root: URL) {
        self.state = state
        self.root = root
        _flow = State(initialValue: CommitFlow(root: root))
    }

    var body: some View {
        ZStack {
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.line.color).frame(height: 1)
                content
                Rectangle().fill(Palette.line.color).frame(height: 1)
                footer
            }
            .frame(width: 860)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .modalShadow()
            .background {
                Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("commit")
        }
        .task {
            flow.draftMessage = { files, diff in await draft(files: files, diff: diff) }
            await flow.refresh()
            if shown == nil, let first = flow.changes.first { await show(first) }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("提交改动").font(FormoraFont.ui(15, weight: 700)).foregroundStyle(Palette.ink.color)
                Text(subtitle).font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color).accessibilityIdentifier("commit.subtitle")
            }
            Spacer()
            IconActionButton(icon: Icons.close, label: "关闭", identifier: "commit.close", action: close)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var subtitle: String {
        if flow.notRepo { return "这个文件夹不是 git 仓库（或者没装 git）。" }
        guard let status = flow.status else { return "正在读取…" }
        let where_ = "分支 \(status.branch)" + (status.upstream.map { " · 跟踪 \($0)" } ?? " · 还没推送过")
        return status.changes.isEmpty ? "没有改动 · " + where_ : "\(status.changes.count) 个改动，勾选要提交的 · " + where_
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let busy = flow.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color).accessibilityIdentifier("commit.busy")
            } else if let outcome = flow.outcome {
                Text(outcomeText(outcome)).font(FormoraFont.ui(12)).foregroundStyle(Palette.success.color).accessibilityIdentifier("commit.result")
                if let url = outcome.pullRequest.flatMap(URL.init(string:)) {
                    Button("打开 PR") { NSWorkspace.shared.open(url) }.buttonStyle(FormoraButtonStyle(kind: .ghost)).accessibilityIdentifier("commit.openPR")
                }
            }
            Spacer()
            Button("取消", action: close).buttonStyle(FormoraButtonStyle(kind: .ghost)).accessibilityIdentifier("commit.cancel")
            Button("提交") { Task { await flow.run(push: false, pullRequest: false) } }
                .buttonStyle(FormoraButtonStyle()).disabled(!flow.canRun).accessibilityIdentifier("commit.run")
            Button("提交并推送") { Task { await flow.run(push: true, pullRequest: false) } }
                .buttonStyle(FormoraButtonStyle()).disabled(!flow.canRun).accessibilityIdentifier("commit.push")
            Button("提交并发 PR") { Task { await flow.run(push: true, pullRequest: true) } }
                .buttonStyle(FormoraButtonStyle(kind: .primary)).disabled(!flow.canRun).accessibilityIdentifier("commit.pr")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func outcomeText(_ outcome: CommitFlow.Outcome) -> String {
        var text = "已提交 \(outcome.commit) 到 \(outcome.branch)"
        if outcome.pushed { text += "，已推送" }
        if outcome.pullRequest != nil { text += "，PR 已开" }
        return text
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                changeList.frame(width: 300)
                diffPane.frame(maxWidth: .infinity)
            }
            .frame(height: 300)
            messageEditor
            if let problem = flow.problem { InlineError(text: problem, identifier: "commit.problem") }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var changeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if flow.changes.isEmpty {
                    Text(flow.loaded ? "没有改动。" : "正在读取…").font(FormoraFont.ui(12)).foregroundStyle(Palette.inkFaint.color).padding(8)
                }
                ForEach(flow.changes) { change in
                    HStack(spacing: 8) {
                        Button {
                            if flow.selected.contains(change.path) { flow.selected.remove(change.path) } else { flow.selected.insert(change.path) }
                        } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(flow.selected.contains(change.path) ? Palette.accent.color : Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
                                .overlay { if flow.selected.contains(change.path) { IconView(Icons.check, size: 10).foregroundStyle(Palette.accentInk.color) } }
                                .frame(width: 15, height: 15)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(flow.selected.contains(change.path) ? "取消勾选" : "勾选")
                        .accessibilityIdentifier("commit.tick")
                        Text(change.kind.mark).font(FormoraFont.mono(11)).foregroundStyle(Palette.inkFaint.color).frame(width: 12)
                        Text(change.path).font(FormoraFont.mono(11.5)).foregroundStyle(Palette.ink.color).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(shown?.path == change.path ? Palette.surfaceRaised.color : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await show(change) } }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("commit.change")
                    .accessibilityLabel(change.kind.label + " " + change.path)
                }
            }
            .padding(4)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ground.color))
        .accessibilityIdentifier("commit.changes")
    }

    private var diffPane: some View {
        ScrollView {
            if let shown {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.path).font(FormoraFont.mono(11)).foregroundStyle(Palette.inkFaint.color).padding(.horizontal, 10).padding(.top, 8)
                    DiffText(text: diff.isEmpty ? "（没有差异）" : diff, maxHeight: 10_000)
                }
            } else {
                Text("点一个文件看它改了什么。").font(FormoraFont.ui(12)).foregroundStyle(Palette.inkFaint.color).padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ground.color))
        .accessibilityIdentifier("commit.diff")
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("提交信息").font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                Spacer()
                Button(flow.drafting ? "正在起草…" : "让 Agent 起草") { Task { await flow.draft() } }
                    .buttonStyle(FormoraButtonStyle(kind: .ghost))
                    .disabled(flow.drafting || flow.selectedChanges.isEmpty)
                    .accessibilityIdentifier("commit.draft")
            }
            FormoraTextEditor(placeholder: "第一行是标题，空一行后写要点", text: Binding(get: { flow.message }, set: { flow.message = $0 }),
                              height: 84, identifier: "commit.message")
        }
    }

    // MARK: Actions

    private func show(_ change: GitChange) async {
        shown = change
        diff = await flow.diff(of: change)
    }

    /// The model drafts from the diff — Bob's model, or the first Agent's; none configured, the fallback stays.
    private func draft(files: [String], diff: String) async -> String? {
        var candidates: [ModelReference] = []
        if let bob = state.bobModel.current(state.providers) { candidates.append(bob) }
        for agent in state.agents.agents {
            if let provider = agent.providerID { candidates.append(ModelReference(providerID: provider, modelID: agent.modelID)) }
        }
        guard !candidates.isEmpty else { return nil }
        let prompt = "改动的文件：\n" + files.map { "- " + $0 }.joined(separator: "\n") + "\n\ndiff：\n" + diff
        return await state.chat.oneShot(system: Self.draftSystem, prompt: prompt, candidates: Array(candidates.prefix(2)))?.summary
    }

    static let draftSystem = """
    你替开发者写 git 提交信息。只输出提交信息本身：第一行是不超过 50 个字的标题，说清改了什么、为什么；需要时空一行，再写 1 到 3 条要点，每条一行，以「- 」开头。用中文，不要 Markdown 标题，不要引号，不要解释。
    """

    private func close() {
        guard flow.busy == nil else { return }
        state.commitSheet = nil
    }
}
