import SwiftUI

/// The closed line of a group at the bottom of a run (spec §6.2): an icon, the summary, a chevron that turns when open.
/// `ToolFoldView` and the three groups of 2026-09-18 share it, so they read as one row of folds.
struct FoldHeader: View {
    let icon: SVGIcon
    let summary: String
    let isOpen: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                IconView(icon, size: 12).foregroundStyle(Palette.inkFaint.color)
                Text(summary)
                    .font(FormoraFont.mono(11))
                    .foregroundStyle(Palette.inkMuted.color)
                    .lineLimit(1)
                IconView(Icons.chevronRight, size: 10)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(Palette.inkFaint.color)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
        .accessibilityIdentifier(identifier)
    }
}

/// 思考折叠 (user 2026-09-18): every turn's thinking of the run in one group. Closed, 「思考 · 3 段 · 共 23 秒」 — or
/// 「思考中…」 while the model thinks; open, each segment with its turn and seconds, the one being written last.
struct ThinkingFoldView: View {
    let thoughts: [RunFolds.Thought]
    /// The model is thinking right now: the header says so, and the segment being written shows a cursor.
    let isThinking: Bool
    var reveal: (AnyHashable) -> Void = { _ in }

    @State private var isOpen = VerificationHooks.opensToolCards

    private var anchor: String { "thinking.fold." + (thoughts.first?.messageID.uuidString ?? "") }

    var body: some View {
        let summary = RunFolds.thinkingSummary(thoughts, isThinking: isThinking)
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FoldHeader(icon: Icons.bulb, summary: summary, isOpen: isOpen, identifier: "thinking.fold.toggle") {
                    isOpen.toggle()
                    if isOpen { revealLater() }
                }
                .disabled(thoughts.isEmpty)
                if isOpen {
                    ForEach(Array(thoughts.enumerated()), id: \.element.id) { index, thought in
                        VStack(alignment: .leading, spacing: 3) {
                            if thoughts.count > 1 {
                                Text("第 \(index + 1) 段" + (thought.seconds.map { " · \(ThinkingFold.duration($0))" } ?? ""))
                                    .font(FormoraFont.mono(10.5))
                                    .foregroundStyle(Palette.inkFaint.color)
                            }
                            Text(thought.text + (isThinking && index == thoughts.count - 1 ? " ▍" : ""))
                                .font(FormoraFont.ui(12))
                                .foregroundStyle(Palette.inkMuted.color)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("reply.thinking.text")
                        }
                        .padding(.leading, 11)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.lineStrong.color).frame(width: 2) }
                    }
                }
            }
            .id(anchor)
            .padding(.horizontal, 3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("thinking.fold")
        }
    }

    private func revealLater() {
        let anchor = anchor
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            reveal(anchor)
        }
    }
}

/// 旁审折叠 (user 2026-09-18): the watcher's 提醒 and 担心 of the run in one group; 必须停 stays in its turn.
struct AdviceFoldView: View {
    let notes: [RunFolds.Advice]
    var reveal: (AnyHashable) -> Void = { _ in }

    @State private var isOpen = VerificationHooks.opensToolCards

    private var anchor: String { "advice.fold." + (notes.first?.messageID.uuidString ?? "") }

    var body: some View {
        let summary = RunFolds.adviceSummary(notes)
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FoldHeader(icon: Icons.eye, summary: summary, isOpen: isOpen, identifier: "advice.fold.toggle") {
                    isOpen.toggle()
                    if isOpen {
                        let anchor = anchor
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            reveal(anchor)
                        }
                    }
                }
                if isOpen {
                    ForEach(notes) { note in AdviceCard(severity: note.severity, text: note.text) }
                }
            }
            .id(anchor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("advice.fold")
        }
    }
}

/// 文件折叠 (user 2026-09-18): the files the run changed in one group. Closed, 「文件 · 改了 3 个 · +120 −8」; open, the save
/// cards as they were — 查看改动, 撤销, 在文件中查看.
struct ChangesFoldView: View {
    let changes: [RunFolds.Change]
    let undo: (RunFolds.Change) -> Void
    let open: (RunFolds.Change) -> Void
    var reveal: (AnyHashable) -> Void = { _ in }

    @State private var isOpen = VerificationHooks.opensToolCards

    private var anchor: String { "changes.fold." + (changes.first?.messageID.uuidString ?? "") }

    var body: some View {
        let summary = RunFolds.changesSummary(changes)
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FoldHeader(icon: Icons.file, summary: summary, isOpen: isOpen, identifier: "changes.fold.toggle") {
                    isOpen.toggle()
                    if isOpen {
                        let anchor = anchor
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(60))
                            reveal(anchor)
                        }
                    }
                }
                if isOpen {
                    ForEach(changes) { file in
                        SaveCard(path: file.path, isNewFile: file.isNew, change: file.change,
                                 undo: file.callID == nil ? nil : { undo(file) }) { open(file) }
                    }
                }
            }
            .id(anchor)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("changes.fold")
        }
    }
}
