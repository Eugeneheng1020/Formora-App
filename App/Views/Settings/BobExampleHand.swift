import SwiftUI

/// 设置 → Bob's examples as a hand of cards (user 2026-09-13): held the way cards are held — their bottoms together, their
/// tops fanned out — each with its number, kind and question. The one clicked rises out of the hand, enlarged over 设置
/// (`BobExampleOverlay`), with how Bob answers it (written ahead, marked 示例回答) and 问 Bob.
struct BobExampleHand: View {
    let state: AppState

    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var examples: [BobExample] { BobExamples.all }

    static let cardSize = CGSize(width: 168, height: 236)
    /// The angle across the whole hand, and the point the cards turn on: below them, so their bottoms stay close.
    static let spread = 64.0
    static let pivot = UnitPoint(x: 0.5, y: 1.8)
    /// A card, the lift of the one under the pointer, and the edge cards sinking as they turn.
    static let height: CGFloat = 316

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(examples.indices, id: \.self) { index in
                card(index)
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.hand")
    }

    private func card(_ index: Int) -> some View {
        let example = examples[index]
        let fraction = examples.count > 1 ? Double(index) / Double(examples.count - 1) - 0.5 : 0
        let isOpen = state.bobExampleOpen == index
        let lifted = hovered == index && state.bobExampleOpen == nil
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                state.bobExampleOpen = index
                hovered = nil
            }
        } label: {
            BobExampleFace(example: example, number: index + 1, highlighted: lifted)
        }
        .buttonStyle(.plain)
        // Raised along its own slant: the offset turns with the card.
        .offset(y: lifted ? -26 : 0)
        .rotationEffect(.degrees(fraction * Self.spread), anchor: Self.pivot)
        // Drawn out, its place in the hand is empty.
        .opacity(isOpen ? 0 : 1)
        .zIndex(lifted ? 100 : Double(index))
        .onHover { inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                hovered = inside ? index : (hovered == index ? nil : hovered)
            }
        }
        .accessibilityLabel("\(example.group.title)：\(example.question)")
        .accessibilityIdentifier("bob.card")
    }
}

/// The card drawn out of the hand, over 设置 with the rest dimmed: ‹ › or ← → turn to another, Esc or a click beside it
/// puts it back, 问 Bob asks him for real in his panel.
struct BobExampleOverlay: View {
    let state: AppState
    let index: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var examples: [BobExample] { BobExamples.all }

    var body: some View {
        ZStack {
            Palette.scrim.color
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            BobExampleCard(example: examples[index], number: index + 1, count: examples.count,
                           canAsk: state.bobModel.current(state.providers) != nil,
                           turn: turn, close: close, ask: ask)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
        }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { state.bobExampleOpen = nil }
    }

    private func turn(_ step: Int) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            state.bobExampleOpen = (index + step + examples.count) % examples.count
        }
    }

    /// In his panel; a question that goes with a file waits in his input for it.
    private func ask() {
        let example = examples[index]
        close()
        state.bobPanelOpen = true
        if example.attachment != nil {
            state.bob.input = example.question
        } else {
            state.bob.send(example.question)
        }
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

/// A card in the hand: its number large in the corner, like a playing card's index, then its kind and question.
private struct BobExampleFace: View {
    let example: BobExample
    let number: Int
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(number)")
                    .font(FormoraFont.mono(20, weight: 700))
                    .foregroundStyle(Palette.accent.color)
                IconView(example.group.icon, size: 13)
                    .foregroundStyle(Palette.inkMuted.color)
            }
            Text(example.group.title)
                .font(FormoraFont.ui(10.5, weight: 600))
                .foregroundStyle(Palette.inkMuted.color)
            Text(example.question)
                .font(FormoraFont.ui(12.5, weight: 600))
                .foregroundStyle(Palette.ink.color)
                .lineSpacing(3)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                IconView(Icons.robot, size: 11)
                Text("看 Bob 怎么答")
                    .font(FormoraFont.ui(10.5))
            }
            .foregroundStyle(Palette.inkFaint.color)
        }
        .padding(14)
        .frame(width: BobExampleHand.cardSize.width, height: BobExampleHand.cardSize.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(highlighted ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
        .softShadow()
    }
}

/// The card drawn out: the question as his panel shows it, his steps and answer, and the way to ask him.
private struct BobExampleCard: View {
    let example: BobExample
    let number: Int
    let count: Int
    let canAsk: Bool
    let turn: (Int) -> Void
    let close: () -> Void
    let ask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                IconView(example.group.icon, size: 13).foregroundStyle(Palette.accent.color)
                Text(example.group.title)
                    .font(FormoraFont.ui(12, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                Text("\(number) / \(count)")
                    .font(FormoraFont.mono(10.5))
                    .foregroundStyle(Palette.inkFaint.color)
                Spacer(minLength: 8)
                IconActionButton(icon: Icons.close, label: "放回去", identifier: "bob.cardClose") { close() }
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
            Rectangle().fill(Palette.line.color).frame(height: 1)
            HStack(spacing: 8) {
                // 问 Bob is off without a model: the reason is here, not in a tooltip.
                Text(canAsk ? "示例回答 · 实际以你的项目和设置为准" : "示例回答 · 先在上面给 Bob 选一个模型，才能问他")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                IconActionButton(icon: Icons.chevronLeft, label: "上一张", identifier: "bob.cardPrev") { turn(-1) }
                IconActionButton(icon: Icons.chevronRight, label: "下一张", identifier: "bob.cardNext") { turn(1) }
                Button("问 Bob", action: ask)
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .disabled(!canAsk)
                    .accessibilityIdentifier("bob.example")
            }
        }
        .padding(18)
        .frame(width: 470, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .modalShadow()
        .background { keys }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.cardOpen")
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
                .frame(maxWidth: 330, alignment: .trailing)
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
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
    }

    /// Esc puts the card back; ← → turn.
    private var keys: some View {
        ZStack {
            Button("") { close() }.keyboardShortcut(.cancelAction)
            Button("") { turn(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { turn(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
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
