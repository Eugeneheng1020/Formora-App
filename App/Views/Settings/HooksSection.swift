import AppKit
import SwiftUI

/// A hook in the list: which file, and where in it.
struct HookTarget: Identifiable, Equatable {
    let scope: HookStore.Scope
    let entry: HookFile.Entry

    var id: String { "\(scope)#\(entry.id)" }
}

enum HookEditorTarget: Identifiable, Equatable {
    case add(HookStore.Scope)
    case edit(HookTarget)

    var id: String {
        switch self {
        case .add(let scope): "add#\(scope)"
        case .edit(let target): target.id
        }
    }
}

/// 设置 → Hooks (7b′, H3–H4): the global hooks and the open project's, as Claude Code writes them. A form adds and
/// edits them; a project's hooks wait for 启用, and ask again after they change.
struct HooksSection: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        let hooks = state.hooks
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .hooks, note: "到了设定的时机自动运行命令或通知网址；写法和 Claude Code 相同。") {
                Button("添加 Hook") { state.hookEditor = .add(.global) }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .accessibilityIdentifier("hooks.add")
            }
            HookFileBlock(state: state, scope: .global, title: "全局", detail: "所有项目都生效", file: hooks.global,
                          problem: hooks.globalProblem, url: hooks.globalURL, pendingCount: nil)
            if let root = session.accessibleRoot, let project = session.current {
                let own = hooks.project(root)
                HookFileBlock(state: state, scope: .project(root), title: "项目 · \(project.name)",
                              detail: ".formora/hooks.json · 只在这个项目里生效", file: own.file, problem: own.problem,
                              url: HookStore.projectURL(root),
                              pendingCount: own.exists && !own.isTrusted && own.problem == nil ? own.file.entries.count : nil)
            }
        }
        .onAppear { state.hooks.reload() }
    }
}

private struct HookFileBlock: View {
    let state: AppState
    let scope: HookStore.Scope
    let title: String
    let detail: String
    let file: HookFile
    let problem: String?
    let url: URL?
    /// The project's hooks exist but aren't switched on (H4): how many.
    let pendingCount: Int?

    private var tag: String { scope == .global ? "global" : "project" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(FormoraFont.ui(13, weight: 600)).foregroundStyle(Palette.ink.color)
                Text(detail).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            .padding(.bottom, 10)
            if let problem {
                // No way to Finder from here (user 2026-09-12), so the message names the file.
                InlineError(text: "hooks.json 读不出来：\(problem)。改正 \(url?.path ?? "hooks.json") 之前，这里的 Hook 都不会运行。",
                            identifier: "hooks.problem.\(tag)")
                    .padding(.bottom, 10)
            }
            if let pendingCount, let root = projectRoot {
                TrustBox(count: pendingCount) {
                    state.hooks.trust(root)
                    state.toasts.show("已启用", note: "这个项目的 \(pendingCount) 个 Hook 会自动运行", seconds: 2)
                }
                .padding(.bottom, 12)
            }
            if file.entries.isEmpty, problem == nil {
                Text(scope == .global ? "还没有全局 Hook。" : "这个项目还没有 Hook。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            } else if !file.entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(file.entries) { entry in HookRow(state: state, scope: scope, entry: entry) }
                }
                .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hooks.list.\(tag)")
            }
        }
    }

    private var projectRoot: URL? {
        if case .project(let root) = scope { return root }
        return nil
    }
}

/// A project's hooks may come from someone else: look first, then switch them on (H4).
private struct TrustBox: View {
    let count: Int
    let trust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这个项目带了 \(count) 个 Hook，还没有启用")
                .font(FormoraFont.ui(12.5, weight: 600))
                .foregroundStyle(Palette.ink.color)
            Text("项目里的 Hook 可能来自别人，看清每一条做什么再启用；文件改过会再问一次。")
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("启用这些 Hook", action: trust)
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .accessibilityIdentifier("hooks.trust")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.accent.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hooks.pending")
    }
}

/// One hook: when, for which tools, what kind; the command or the URL; edit and delete.
private struct HookRow: View {
    let state: AppState
    let scope: HookStore.Scope
    let entry: HookFile.Entry

    private static let toolLabels = Dictionary(uniqueKeysWithValues: HookEditorDialog.tools.map { ($0.name, $0.label) })

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SmallTag(text: entry.known?.label ?? entry.event, accent: entry.known != nil)
                    if entry.known?.usesToolMatcher == true { SmallTag(text: tools) }
                    SmallTag(text: kind)
                    if let timeout = entry.handler.timeout { SmallTag(text: "\(timeout) 秒") }
                }
                Text(content)
                    .font(FormoraFont.mono(11.5))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
                    .padding(.top, 8)
                if let unsupported {
                    Text(unsupported).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if entry.known != nil, entry.handler.isRunnable {
                    IconActionButton(icon: Icons.pencil, label: "编辑这个 Hook", identifier: "hooks.edit.\(entry.id)") {
                        state.hookEditor = .edit(HookTarget(scope: scope, entry: entry))
                    }
                }
                IconActionButton(icon: Icons.trash, label: "删除这个 Hook", identifier: "hooks.delete.\(entry.id)") {
                    state.hookToDelete = HookTarget(scope: scope, entry: entry)
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hooks.row")
    }

    private var tools: String {
        let matcher = (entry.matcher ?? "").trimmingCharacters(in: .whitespaces)
        if matcher.isEmpty || matcher == "*" { return "全部工具" }
        let names = matcher.split(whereSeparator: { $0 == "|" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let labels = names.map { Self.toolLabels[$0] }
        return labels.allSatisfy { $0 != nil } ? labels.compactMap { $0 }.joined(separator: " · ") : matcher
    }

    private var kind: String {
        switch entry.handler.kind {
        case .command: "命令"
        case let .http(_, format): format.label
        case .unsupported(let type): type
        }
    }

    private var content: String {
        switch entry.handler.kind {
        case .command(let command): command
        case let .http(url, _): url
        case .unsupported: "—"
        }
    }

    private var unsupported: String? {
        if entry.known == nil { return "Formora 还没有「\(entry.event)」这个时机，保留在文件里，不会运行" }
        if case .unsupported(let type) = entry.handler.kind { return "Formora 还不支持「\(type)」这种形式，保留在文件里，不会运行" }
        return nil
    }
}
