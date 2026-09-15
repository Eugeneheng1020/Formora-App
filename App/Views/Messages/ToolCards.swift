import AppKit
import SwiftUI

/// One tool call in a reply (7b, old D14): what it does and how it went; its output folds open. A call waiting for
/// 允许 / 拒绝 only says so here — the decision is above the composer (user 2026-09-15, `ApprovalPanel`).
struct ToolCallCard: View {
    enum Phase: Equatable {
        case queued, running
        /// Waiting for 允许 / 拒绝 above the composer.
        case waiting
        case finished(ToolResult)
    }

    let call: ToolCall
    let phase: Phase

    @State private var isOpen = VerificationHooks.opensToolCards

    private var isWaiting: Bool { phase == .waiting }

    private var output: String? {
        if case .finished(let result) = phase, !result.output.isEmpty { return result.output }
        return nil
    }

    /// A short output at its own height; a long one scrolls within 200pt — a scroll view alone always takes the 200.
    @ViewBuilder private func outputView(_ output: String) -> some View {
        let text = Text(output)
            .font(FormoraFont.mono(11))
            .foregroundStyle(Palette.inkMuted.color)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
        if output.count > 1_200 || output.reduce(0, { $1 == "\n" ? $0 + 1 : $0 }) > 10 {
            ScrollView { text }.frame(maxHeight: 200)
        } else {
            text
        }
    }

    /// Pictures the call handed the model (7j, V1).
    private var images: [String] {
        if case .finished(let result) = phase { return result.images ?? [] }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if output != nil { isOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    IconView(Self.icon(for: call.name), size: 13).foregroundStyle(Palette.inkMuted.color)
                    Text(call.summary)
                        .font(FormoraFont.mono(11.5))
                        .foregroundStyle(Palette.ink.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    status
                    if output != nil {
                        IconView(Icons.chevronRight, size: 10)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(Palette.inkFaint.color)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(output == nil)
            if isWaiting {
                Text("在输入框上方确认")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.bottom, 9)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("tool.waitingHint")
            }
            if isOpen, let output {
                outputView(output)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .accessibilityIdentifier("tool.output")
                if !images.isEmpty { ToolImages(paths: images) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isWaiting ? Palette.accent.color : Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool.\(call.name)")
    }

    /// The tool's mark, here and on the approval panel.
    static func icon(for name: String) -> SVGIcon {
        switch name {
        case "read", "fetch": Icons.file
        case "glob", "grep", "web_search": Icons.search
        case "write", "edit": Icons.pencil
        case "bash", "bash_output", "bash_stop": Icons.terminal
        case "open_url": Icons.arrowUpRight
        case "skill", "skill_create": Icons.sparkle
        case "remember": Icons.bulb
        case ComputerTool.name: Icons.display
        case ScriptTools.osascript.name, ScriptTools.shortcutList.name, ScriptTools.shortcutRun.name: Icons.terminal
        case let name where name.hasPrefix(MCPTools.prefix): Icons.plug
        default: Icons.chip
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .queued:
            label("排队中", Palette.inkFaint.color)
        case .waiting:
            label("等你确认", Palette.accent.color)
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                label("进行中", Palette.inkMuted.color)
            }
        case .finished(let result):
            switch result.status {
            case .done:
                // A command handed to the background (10f) isn't finished — it runs on, listed above the composer.
                if Self.startedInBackground(call, result) {
                    label("已转到后台", Palette.accent.color)
                } else {
                    label("完成", Palette.success.color)
                }
            case .failed: label("失败", Palette.alert.color)
            case .denied: label("已拒绝", Palette.inkMuted.color)
            case .stopped: label("已停止", Palette.inkFaint.color)
            }
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text).font(FormoraFont.ui(11, weight: 600)).foregroundStyle(color).accessibilityIdentifier("tool.status")
    }

    /// 10f: a bash call that left its command running — not one that ended within the first wait.
    static func startedInBackground(_ call: ToolCall, _ result: ToolResult) -> Bool {
        call.name == AgentTools.bash.name && BackgroundJobs.wantsBackground(call.arguments) && result.output.hasPrefix("已在后台运行")
    }
}

/// `.save-card` (old D17): a file the Agent wrote — 文件已保存 / 文件已修改, its real path, and 在文件中查看, which
/// shows it in 文件 (spec §8.8's 「去看看」).
/// Pictures a call handed the model — an image `read`, a screenshot (7j, V1): thumbnails under its output.
private struct ToolImages: View {
    let paths: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(paths, id: \.self) { path in
                    if let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                    } else {
                        Text("图片已经不在了：\((path as NSString).lastPathComponent)")
                            .font(FormoraFont.ui(11))
                            .foregroundStyle(Palette.inkFaint.color)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .accessibilityIdentifier("tool.images")
    }
}

struct SaveCard: View {
    let path: String
    let isNewFile: Bool
    /// 10d: what the step changed; `nil` for a file written before there was a history.
    var change: FileChange? = nil
    /// 10d: 撤销, when the change can be undone.
    var undo: (() -> Void)? = nil
    let open: () -> Void

    @State private var showsDiff = VerificationHooks.opensToolCards

    private var isUndone: Bool { change?.undone == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                IconView(isUndone ? Icons.close : Icons.check, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(isUndone ? "已撤销" : isNewFile ? "文件已保存" : "文件已修改").font(FormoraFont.ui(12.5))
                        if let change, !isUndone, change.added + change.removed > 0 {
                            Text("+\(change.added)").font(FormoraFont.mono(11)).foregroundStyle(Palette.success.color)
                            Text("−\(change.removed)").font(FormoraFont.mono(11)).foregroundStyle(Palette.alert.color)
                        }
                    }
                    Text(path)
                        .font(FormoraFont.mono(11.5))
                        .opacity(0.85)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("save.path")
                }
                Spacer(minLength: 10)
                if change?.diff != nil, !isUndone {
                    capsule(showsDiff ? "收起改动" : "查看改动", identifier: "save.diff") { showsDiff.toggle() }
                }
                if let undo, let change, FileHistory.canUndo(change) {
                    capsule("撤销", identifier: "save.undo", action: undo)
                }
                if !isUndone { capsule("在文件中查看", identifier: "save.open", action: open) }
            }
            if showsDiff, let diff = change?.diff, !isUndone {
                DiffText(text: diff, maxHeight: 280)
            }
        }
        .foregroundStyle(isUndone ? Palette.inkMuted.color : Palette.success.color)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: showsDiff ? 640 : 500, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isUndone ? Palette.surfaceRaised.color : Palette.successSoft.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isUndone ? Palette.line.color : Palette.successLine.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("save.card")
    }

    private func capsule(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FormoraFont.ui(11.5))
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .overlay(Capsule().strokeBorder(Palette.successLine.color, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// 10d: a change as `git diff` has it, read by someone who isn't a programmer — the mark in a column of its own (a
/// document's own `- ` list stays apart from it), added lines green, removed ones red, a hunk's header as 「第 N 行起」;
/// a long one scrolls within its height.
struct DiffText: View {
    let text: String
    var maxHeight: CGFloat = 240

    private var lines: [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLastEmpty() }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.mark(line))
                        .frame(width: 10, alignment: .center)
                    Text(Self.body(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(FormoraFont.mono(11))
                .foregroundStyle(color(line))
                .padding(.horizontal, 10)
                .padding(.top, line.hasPrefix("@@") && lines.first != line ? 6 : 0)
                .background(background(line))
            }
        }
        .padding(.vertical, 6)
        .textSelection(.enabled)
        Group {
            if lines.count > 16 { ScrollView { content }.frame(maxHeight: maxHeight) } else { content }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface.color))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("diff.text")
    }

    /// `+`, `−`, or nothing for a line that stays and for a hunk's header.
    static func mark(_ line: String) -> String {
        if line.hasPrefix("+") { return "+" }
        if line.hasPrefix("-") { return "−" }
        return " "
    }

    /// The line without its mark; a hunk's `@@ -a,b +c,d @@` as where it starts in the new file.
    static func body(_ line: String) -> String {
        if line.hasPrefix("@@") {
            let start = line.range(of: #"\+(\d+)"#, options: .regularExpression).map { String(line[$0].dropFirst()) } ?? "1"
            return "第 \(max(Int(start) ?? 1, 1)) 行起"
        }
        let rest = String(line.dropFirst())
        return rest.isEmpty ? " " : rest
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("@@") { return Palette.inkFaint.color }
        if line.hasPrefix("+") { return Palette.success.color }
        if line.hasPrefix("-") { return Palette.alert.color }
        return Palette.inkMuted.color
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+") { return Palette.success.color.opacity(0.1) }
        if line.hasPrefix("-") { return Palette.alert.color.opacity(0.1) }
        return .clear
    }
}

private extension Array where Element == String {
    func dropLastEmpty() -> [String] { last == "" ? Array(dropLast()) : self }
}

/// The run stopped to ask 「继续？」 (7b, L2) — after 50 model calls or an hour; docked above the composer (user 2026-09-15).
struct PauseCard: View {
    let reason: String
    let resume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("要继续吗？").font(FormoraFont.ui(12.5, weight: 700)).foregroundStyle(Palette.ink.color)
                Spacer(minLength: 12)
                Text("PAUSED").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
            }
            .padding(.bottom, 11)
            Text("\(reason)看一下它做到哪了：要它接着做就点「继续」，也可以直接发消息告诉它下一步。")
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("继续", action: resume)
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .accessibilityIdentifier("run.resume")
            }
            .padding(.top, 12)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("run.pause")
    }
}
