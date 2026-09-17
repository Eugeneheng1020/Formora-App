import SwiftUI

/// Where a compaction folded the thread (7e, E5; mockup `.compact-divider`): a dashed line with what happened, 「看摘要」
/// for what the model reads now and 「展开原文」 for the folded messages — nothing is deleted (spec §9.8d).
struct CompactDivider: View {
    let record: CompactionRecord
    let foldedCount: Int
    let isExpanded: Bool
    var showsSummaryInitially = false
    let toggleExpanded: () -> Void

    @State private var showsSummary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Text("已压缩 \(foldedCount) 条消息 · \(ContextBudget.format(record.tokensBefore)) → \(ContextBudget.format(record.tokensAfter)) token（估算）· \(record.reason.label)")
                    .font(FormoraFont.mono(10.5))
                    .foregroundStyle(Palette.inkFaint.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("compact.divider.text")
                SmallButton(title: showsSummary ? "收起摘要" : "看摘要", identifier: "compact.summary") { showsSummary.toggle() }
                SmallButton(title: isExpanded ? "收起原文" : "展开原文", identifier: "compact.expand", action: toggleExpanded)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.lineStrong.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            if showsSummary {
                MarkdownText(source: record.summary)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 640, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                    .accessibilityIdentifier("compact.summary.text")
            }
        }
        .onAppear { if showsSummaryInitially { showsSummary = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compact.divider")
    }
}

/// A compaction under way (E5).
struct CompactingRow: View {
    let reason: CompactionRecord.Reason

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在压缩上下文… · \(reason.label)")
                .font(FormoraFont.ui(11.5))
                .foregroundStyle(Palette.inkFaint.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityIdentifier("compact.running")
    }
}

/// `.btn` at its small size (min-height 26, 11.5px).
struct SmallButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FormoraFont.ui(11.5, weight: 600))
                .foregroundStyle(Palette.ink.color)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.surfaceRaised2.color : Palette.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(identifier)
    }
}

/// The ring before 发送 (7e, E7; user 2026-09-06): how much of the model's window the context takes, alert from 85%.
/// The numbers are in its tooltip, marked 估算; a click opens `/cost`.
struct ContextRing: View {
    let usage: ContextBudget.Usage
    let open: () -> Void

    var body: some View {
        let ratio = min(1, usage.ratio ?? 0)
        let hot = ratio >= ContextBudget.hintRatio
        Button(action: open) {
            ZStack {
                Circle().stroke(Palette.lineStrong.color, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(hot ? Palette.alert.color : Palette.accent.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 17, height: 17)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(note)
        .accessibilityLabel("上下文用量")
        .accessibilityValue(note)
        .accessibilityIdentifier("composer.contextRing")
    }

    private var note: String {
        guard let window = usage.window else {
            return "上下文约 \(ContextBudget.format(usage.tokens)) token（估算）；不知道这个模型的窗口大小。点开看用量"
        }
        let percent = Int(((usage.ratio ?? 0) * 100).rounded())
        return "上下文约 \(ContextBudget.format(usage.tokens)) / \(ContextBudget.format(window)) token，\(percent)%（估算）。点开看用量"
    }
}

/// `/memory` (7f, F4; user 2026-09-17): what this conversation's Agent reads — what holds everywhere, the project's, its
/// own — a layer a group, read-only. A note with more to it opens; the ones gone stale are listed apart (10j).
struct MemorySummary: View {
    struct Group: Identifiable {
        let scope: MemoryScope
        let title: String
        let fresh: [MemoryEntry]
        let stale: [MemoryEntry]

        var id: String { scope.name }
    }

    let groups: [Group]

    @MainActor
    static func groups(_ memory: MemoryStore?, conversation: Conversation, agent: AgentRecord?, now: Date = .now) -> [Group] {
        guard let memory else { return [] }
        var scopes: [(MemoryScope, String)] = [(.global, "全局 · 任何项目、每个 Agent 都读得到"), (.project(conversation.projectID), "项目 · 这个项目里的 Agent 共用")]
        if let agent { scopes.append((.agent(agent.id), "\(agent.displayName) 自己的 · 不分项目")) }
        return scopes.map { Group(scope: $0.0, title: $0.1, fresh: memory.fresh($0.0, now: now), stale: memory.stale($0.0, now: now)) }
            .filter { !$0.fresh.isEmpty || !$0.stale.isEmpty }
    }

    var body: some View {
        if groups.isEmpty {
            Text("还没有记忆。你让它记住的、纠正过它的、拍过板的事，和它踩过的坑，会出现在这里。")
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkFaint.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.empty")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .font(FormoraFont.ui(11.5, weight: 600))
                            .foregroundStyle(Palette.inkMuted.color)
                        ForEach(group.fresh) { MemoryLine(entry: $0, isStale: false) }
                        if !group.stale.isEmpty {
                            Text("很久没用到（半年多没再读到或确认，不再列给 Agent；它再用到就恢复）")
                                .font(FormoraFont.ui(11))
                                .foregroundStyle(Palette.inkFaint.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                            ForEach(group.stale) { MemoryLine(entry: $0, isStale: true) }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("memory.group.\(group.scope.name)")
                }
            }
        }
    }
}

/// One note in /memory: its number, its sentence, its day; the body under it once opened.
private struct MemoryLine: View {
    let entry: MemoryEntry
    let isStale: Bool

    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(entry.id).font(FormoraFont.mono(11)).foregroundStyle(Palette.inkFaint.color).frame(minWidth: 22, alignment: .leading)
                Text(entry.summary)
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(isStale ? Palette.inkFaint.color : Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if entry.hasBody {
                    Button(isOpen ? "收起" : "正文") { isOpen.toggle() }
                        .buttonStyle(.plain)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(Palette.accent.color)
                        .accessibilityIdentifier("memory.body.toggle")
                }
                Text(entry.used).font(FormoraFont.mono(10.5)).foregroundStyle(Palette.inkFaint.color)
            }
            if isOpen, entry.hasBody {
                Text(entry.body)
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkMuted.color)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
                    .accessibilityIdentifier("memory.body")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isStale ? "memory.stale" : "memory.note")
    }
}

/// `/cost` (E6): 耗时, Token, 模型调用, then per model what went in, what came from the cache and what came out.
struct UsageSummary: View {
    let report: UsageReport
    let modelName: (ModelReference) -> String

    var body: some View {
        if report.isEmpty {
            Text("这条对话还没有用量记录。Agent 回复之后，这里会显示用了多少 token。")
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkFaint.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("usage.empty")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 26) {
                    metric("耗时", Self.duration(report.seconds))
                    metric("Token", ContextBudget.format(report.tokens))
                    metric("模型调用", "\(report.calls) 次")
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelName(row.model)).font(FormoraFont.mono(11.5)).foregroundStyle(Palette.ink.color)
                            Text("输入 \(ContextBudget.format(row.input))（缓存命中 \(ContextBudget.format(row.cached))）· 输出 \(ContextBudget.format(row.output)) · \(row.calls) 次")
                                .font(FormoraFont.ui(11.5))
                                .foregroundStyle(Palette.inkMuted.color)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("usage.row")
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
            Text(value).font(FormoraFont.mono(13)).foregroundStyle(Palette.ink.color)
        }
        .accessibilityElement(children: .combine)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? "\(total / 60) 分 \(total % 60) 秒" : "\(total) 秒"
    }
}
