import SwiftUI

/// 「思考中…」 while the model thinks, 「思考了 N 秒」 after; folded by default, one click shows the thinking
/// (old app 2026-09-06: the wait isn't a black box, and the answer stays the main thing).
struct ThinkingFold: View {
    let text: String
    let seconds: Double?
    let isThinking: Bool

    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 5) {
                    IconView(Icons.bulb, size: 12)
                    Text(isThinking ? "思考中…" : "思考了 \(Self.duration(seconds))").font(FormoraFont.ui(11.5))
                    if !text.isEmpty {
                        IconView(Icons.chevronRight, size: 10).rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .foregroundStyle(Palette.inkFaint.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .accessibilityLabel(isThinking ? "思考中" : "思考过程")
            .accessibilityIdentifier("reply.thinking")
            if isOpen, !text.isEmpty {
                Text(text)
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkMuted.color)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 11)
                    .overlay(alignment: .leading) { Rectangle().fill(Palette.lineStrong.color).frame(width: 2) }
                    .accessibilityIdentifier("reply.thinking.text")
            }
        }
        .padding(.horizontal, 3)
    }

    static func duration(_ seconds: Double?) -> String {
        let value = max(1, Int((seconds ?? 0).rounded()))
        return value < 60 ? "\(value) 秒" : "\(value / 60) 分 \(value % 60) 秒"
    }
}

/// `.typing-row`: three bobbing dots before the first word arrives.
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (time / 1.1 - Double(index) * 0.14).truncatingRemainder(dividingBy: 1)
                    let lift = phase > 0 && phase < 0.3 ? sin(phase / 0.3 * .pi) : 0
                    Circle()
                        .fill(Palette.inkFaint.color)
                        .frame(width: 5, height: 5)
                        .opacity(0.4 + 0.6 * lift)
                        .offset(y: -3 * lift)
                }
            }
        }
        .frame(height: 16)
        .padding(.horizontal, 3)
        .accessibilityLabel("正在回复")
        .accessibilityIdentifier("reply.typing")
    }
}

/// A reply that didn't come: why, and 重试 on the latest one.
struct FailedReply: View {
    let reason: String
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 12,
                                           style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                IconView(Icons.alertCircle, size: 14)
                Text("没有回复").font(FormoraFont.ui(13, weight: 600))
            }
            .foregroundStyle(Palette.alert.color)
            Text(reason)
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reply.failure")
            if canRetry {
                Button("重试", action: retry)
                    .buttonStyle(FormoraButtonStyle())
                    .accessibilityIdentifier("reply.retry")
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(shape.fill(Palette.alertSoft.color))
        .overlay(shape.strokeBorder(Palette.alertLine.color, lineWidth: 1))
    }
}

/// `.send-btn.stopping`: the send button while a reply streams — 停止生成 (spec §9.6).
struct StopButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Palette.ink.color)
                .frame(width: 11, height: 11)
                .frame(width: 34, height: 34)
                .background(Circle().fill(isHovering ? Palette.lineStrong.color : Palette.surfaceRaised2.color))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("停止生成")
        .accessibilityLabel("停止生成")
        .accessibilityIdentifier("composer.stop")
    }
}
