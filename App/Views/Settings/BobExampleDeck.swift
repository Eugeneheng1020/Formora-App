import SwiftUI

/// 设置 → Bob's examples as a stacked deck (user 2026-09-14, after a fanned hand): one whole card in front — the question
/// as his panel shows it, his steps and answer, 问 Bob — with the next two edging out beneath it. ‹ › in its head, the
/// dots under it, or ← → with the deck focused turn to another. The answers are written ahead (`BobExamples`) and say
/// 示例回答.
struct BobExampleDeck: View {
    let state: AppState

    @State private var index = 0
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var examples: [BobExample] { BobExamples.all }
    /// Tall enough for the longest example, so turning never moves what is below.
    static let cardHeight: CGFloat = 352
    /// How far each card beneath edges out.
    static let edge: CGFloat = 9

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .top) {
                // The two beneath: narrower and lower, like a pile seen from the front.
                beneath(2)
                beneath(1)
                BobExampleCard(state: state, example: examples[index], number: index + 1, count: examples.count, turn: turn)
                    .id(index)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(x: forward ? 36 : -36).combined(with: .opacity),
                        removal: .offset(x: forward ? -36 : 36).combined(with: .opacity)))
            }
            .frame(height: Self.cardHeight + Self.edge * 2, alignment: .top)
            dots
        }
        .padding(.top, 14)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            turn(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            turn(1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.deck")
    }

    /// A card `depth` places under the one in front: only its lower edge shows.
    private func beneath(_ depth: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return shape
            .fill(Palette.surface.color)
            .overlay(shape.strokeBorder(Palette.line.color, lineWidth: 1))
            .frame(height: Self.cardHeight)
            .padding(.horizontal, CGFloat(depth) * 14)
            .offset(y: CGFloat(depth) * Self.edge)
            .opacity(depth == 1 ? 0.8 : 0.5)
    }

    private var dots: some View {
        HStack(spacing: 2) {
            ForEach(examples.indices, id: \.self) { dot in
                Button { go(dot) } label: {
                    Circle()
                        .fill(dot == index ? Palette.accent.color : Palette.lineStrong.color)
                        .frame(width: 7, height: 7)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("第 \(dot + 1) 张：\(examples[dot].question)")
                .accessibilityIdentifier("bob.cardDot")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func turn(_ step: Int) {
        go((index + step + examples.count) % examples.count, forward: step > 0)
    }

    private func go(_ target: Int, forward: Bool? = nil) {
        guard target != index else { return }
        self.forward = forward ?? (target > index)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { index = target }
    }
}

private extension BobExample.Group {
    var icon: SVGIcon {
        switch self {
        case .howTo: Icons.bulb
        case .status: Icons.search
        case .settings: Icons.settings
        case .work: Icons.sparkle
        }
    }
}

/// The card in front: its kind and place with ‹ ›, the question as his panel shows it, his steps and answer, and the
/// way to ask him for real.
private struct BobExampleCard: View {
    let state: AppState
    let example: BobExample
    let number: Int
    let count: Int
    let turn: (Int) -> Void

    private var canAsk: Bool { state.bobModel.current(state.providers) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                IconView(example.group.icon, size: 13).foregroundStyle(Palette.accent.color)
                Text(example.group.title)
                    .font(FormoraFont.ui(12, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                Spacer(minLength: 8)
                IconActionButton(icon: Icons.chevronLeft, label: "上一张", identifier: "bob.cardPrev") { turn(-1) }
                Text("\(number) / \(count)")
                    .font(FormoraFont.mono(10.5))
                    .foregroundStyle(Palette.inkFaint.color)
                IconActionButton(icon: Icons.chevronRight, label: "下一张", identifier: "bob.cardNext") { turn(1) }
            }
            question
            ForEach(example.steps.indices, id: \.self) { index in
                BobExampleStep(step: example.steps[index])
            }
            if let result = example.result {
                resultCard(result)
            }
            Text(example.answer)
                .font(FormoraFont.ui(12.5))
                .foregroundStyle(Palette.ink.color)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bob.cardAnswer")
            if let needs = example.needs {
                Text(needs)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Rectangle().fill(Palette.line.color).frame(height: 1)
            HStack(spacing: 8) {
                // 问 Bob is off without a model: the reason is here, not in a tooltip.
                Text(canAsk ? "示例回答 · 实际以你的项目和设置为准" : "示例回答 · 先在上面给 Bob 选一个模型，才能问他")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("问 Bob", action: ask)
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .disabled(!canAsk)
                    .accessibilityIdentifier("bob.example")
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: BobExampleDeck.cardHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.exampleCard")
    }

    /// His panel's user bubble, on the right.
    private var question: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(example.question)
                .font(FormoraFont.ui(12.5))
                .foregroundStyle(Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                .frame(maxWidth: 460, alignment: .trailing)
                .accessibilityIdentifier("bob.cardQuestion")
            if let attachment = example.attachment {
                Text("附件：\(attachment)")
                    .font(FormoraFont.mono(10.5))
                    .foregroundStyle(Palette.inkFaint.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// His panel's result card, without the jump: nothing here was really made.
    private func resultCard(_ result: BobExample.Result) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                IconView(Icons.check, size: 13).foregroundStyle(Palette.success.color)
                Text(result.title)
                    .font(FormoraFont.ui(12, weight: 600))
                    .foregroundStyle(Palette.ink.color)
            }
            Text(result.meta)
                .font(FormoraFont.mono(10.5))
                .foregroundStyle(Palette.inkFaint.color)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
    }

    /// In his panel; a question that goes with a file waits in his input for it.
    private func ask() {
        state.bobPanelOpen = true
        if example.attachment != nil {
            state.bob.input = example.question
        } else {
            state.bob.send(example.question)
        }
    }
}

/// A finished step as his panel shows it (`BobStepCard`): what it did, 完成, and that it had asked.
private struct BobExampleStep: View {
    let step: BobExample.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                IconView(icon, size: 12).foregroundStyle(Palette.inkMuted.color)
                Text(step.summary)
                    .font(FormoraFont.mono(11))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(step.status)
                    .font(FormoraFont.ui(10.5, weight: 600))
                    .foregroundStyle(Palette.success.color)
            }
            if step.allowed {
                Text("先弹卡片问了你，你点了「允许」")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
    }

    private var icon: SVGIcon {
        switch step.kind {
        case .read: Icons.file
        case .search: Icons.search
        case .skill: Icons.sparkle
        case .plug: Icons.plug
        case .bell: Icons.bell
        case .write: Icons.pencil
        case .terminal: Icons.terminal
        case .computer: Icons.display
        }
    }
}
