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

/// `/memory` (7f, F4): what the Agent remembered about this project — read-only (spec §8.3 keeps its management
/// out of the app; this is only visibility).
struct MemorySummary: View {
    let text: String?
    var now: Date = .now

    var body: some View {
        if let text {
            // 10j: what the Agent is given, then what went stale — kept, listed apart, not given.
            let split = MemoryStore.split(text, now: now)
            VStack(alignment: .leading, spacing: 12) {
                if !split.kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownText(source: split.kept)
                        .accessibilityIdentifier("memory.text")
                }
                if !split.stale.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("很久没用到（半年多没再写下或确认，不再给 Agent 看；它再记一次就恢复）")
                            .font(FormoraFont.ui(11.5, weight: 600))
                            .foregroundStyle(Palette.inkMuted.color)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(split.stale, id: \.self) { line in
                            Text(line)
                                .font(FormoraFont.ui(12))
                                .foregroundStyle(Palette.inkFaint.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("memory.stale")
                }
            }
        } else {
            Text("还没有记忆。Agent 记下的偏好、约定和定下来的结论会出现在这里。")
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkFaint.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("memory.empty")
        }
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
