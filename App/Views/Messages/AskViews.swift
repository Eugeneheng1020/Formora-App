import SwiftUI

/// The question docked above the composer (7d, D6; spec §9.8b, mockup `.choice-panel`): in the normal flow, never
/// over the last message; option cards with what each means; one question at a time; multi-select confirms with
/// 确定; ↑↓ and Enter once it has focus; and a standing line that the user can answer in their own words. Several
/// questions: 上一步 shows an earlier one with its answer, which can be changed (user 2026-09-15).
struct AskPanel: View {
    let state: AppState
    let conversationID: UUID
    let questions: [AskTool.Question]

    @State private var selection: Set<Int> = []
    @State private var cursor: Int?
    /// An earlier question shown again; `nil` = the one in hand.
    @State private var viewing: Int?
    @FocusState private var isFocused: Bool

    private var answered: [AskTool.Answer] { state.askAnswers[conversationID] ?? [] }
    private var nav: AskNavigation { AskNavigation(count: questions.count, answered: answered, viewing: viewing) }
    private var index: Int { nav.index }
    private var question: AskTool.Question { questions[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(questions.count > 1 ? "需要你确认 · \(index + 1)/\(questions.count)" : "需要你确认")
                        .font(FormoraFont.mono(10))
                        .foregroundStyle(Palette.accent.color)
                        .accessibilityIdentifier("ask.step")
                    Spacer(minLength: 0)
                    if nav.canGoBack {
                        stepButton("‹ 上一步", identifier: "ask.back") { move { $0.back() } }
                    }
                    if nav.canGoForward {
                        stepButton("下一步 ›", identifier: "ask.forward") { move { $0.forward() } }
                    }
                }
                Text(question.question)
                    .font(FormoraFont.ui(13, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.question")
                if question.multi {
                    Text("可以选多个，选好点「确定」").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
                }
            }
            .padding(.bottom, 10)
            VStack(spacing: 6) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { offset, option in
                    AskOptionButton(option: option, isRecommended: question.recommended == offset, isMulti: question.multi,
                                    isSelected: selection.contains(offset), isOn: isFocused && cursor == offset) { pick(offset) }
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(nav.canGoForward ? "改一个选项就换成新的答案；不改就点「下一步」。" : "也可以直接在下面输入框里说，不一定要选这几个。")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if question.multi {
                    Button("确定", action: confirm)
                        .buttonStyle(FormoraButtonStyle(kind: .primary))
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("ask.confirm")
                }
            }
            .padding(.top, 9)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveCursor(-1) }
        .onKeyPress(.downArrow) { moveCursor(1) }
        .onKeyPress(.return) {
            guard let cursor else { return .ignored }
            pick(cursor)
            return .handled
        }
        .onAppear { preselect() }
        .onChange(of: index) { preselect() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.panel")
    }

    private func stepButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(FormoraFont.ui(11, weight: 600)).foregroundStyle(Palette.accent.color)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// The shown question's recorded picks, selected again.
    private func preselect() {
        let picked = nav.picked
        selection = Set(question.options.enumerated().filter { picked.contains($0.element.label) }.map(\.offset))
        cursor = nil
    }

    private func move(_ change: (inout AskNavigation) -> Void) {
        var nav = nav
        change(&nav)
        viewing = nav.viewing
    }

    private func moveCursor(_ step: Int) -> KeyPress.Result {
        let count = question.options.count
        cursor = ((cursor ?? (step > 0 ? -1 : 0)) + step + count) % count
        return .handled
    }

    private func pick(_ offset: Int) {
        guard question.options.indices.contains(offset) else { return }
        if question.multi {
            if selection.contains(offset) { selection.remove(offset) } else { selection.insert(offset) }
            return
        }
        record(AskTool.Answer(picked: [question.options[offset].label]))
    }

    private func confirm() {
        guard !selection.isEmpty else { return }
        record(AskTool.Answer(picked: selection.sorted().map { question.options[$0].label }))
    }

    private func record(_ answer: AskTool.Answer) {
        var nav = nav
        let finished = nav.record(answer)
        viewing = nav.viewing
        if finished {
            state.askAnswers[conversationID] = nil
            state.chat.answer(conversationID, nav.answered)
        } else {
            state.askAnswers[conversationID] = nav.answered
        }
    }
}

/// `.choice-option`: the label (12.5/600) and what it means (11, faint); the recommended one says so after its name.
/// A question's option, and a reply's numbered way (user 2026-09-15).
struct AskOptionButton: View {
    let option: AskTool.Option
    let isRecommended: Bool
    let isMulti: Bool
    let isSelected: Bool
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let highlighted = isOn || isHovering
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                if isMulti {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(isSelected ? Palette.accent.color : Palette.inkFaint.color, lineWidth: 1.2)
                        .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(isSelected ? Palette.accent.color : .clear))
                        .overlay { if isSelected { IconView(Icons.check, size: 10).foregroundStyle(Palette.accentInk.color) } }
                        .frame(width: 14, height: 14)
                        .padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                        if isRecommended {
                            Text("推荐").font(FormoraFont.ui(10.5, weight: 600)).foregroundStyle(Palette.accent.color)
                        }
                    }
                    if let description = option.description {
                        Text(description)
                            .font(FormoraFont.ui(11))
                            .foregroundStyle(Palette.inkFaint.color)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? Palette.surfaceRaised2.color : Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(highlighted || isSelected ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(option.label + (isRecommended ? "，推荐" : "") + (option.description.map { "。\($0)" } ?? ""))
        .accessibilityIdentifier("ask.option")
    }
}

/// The question in the run's frame (D6): what was asked and what came back — picked options with a success tick,
/// typed words quoted (spec §9.8b: the two must be told apart).
struct AskCard: View {
    let call: ToolCall
    let isWaiting: Bool

    var body: some View {
        let questions = (try? AskTool.parse(call.arguments).get()) ?? []
        VStack(alignment: .leading, spacing: 9) {
            Text(isWaiting ? "等你回答" : call.result?.status == .done ? "问了你" : "没有问出去")
                .font(FormoraFont.mono(10))
                .foregroundStyle(isWaiting ? Palette.alert.color : Palette.inkFaint.color)
            ForEach(Array(questions.enumerated()), id: \.offset) { offset, question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question)
                        .font(FormoraFont.ui(12, weight: 600))
                        .foregroundStyle(Palette.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    answer(offset)
                }
            }
            if questions.isEmpty, let output = call.result?.output {
                Text(output).font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color).lineLimit(3)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.card")
    }

    @ViewBuilder private func answer(_ offset: Int) -> some View {
        if let answers = call.result?.answers, answers.indices.contains(offset) {
            let answer = answers[offset]
            if !answer.picked.isEmpty {
                ForEach(answer.picked, id: \.self) { label in
                    HStack(spacing: 6) {
                        IconView(Icons.check, size: 11).foregroundStyle(Palette.success.color)
                        Text(label).font(FormoraFont.ui(12)).foregroundStyle(Palette.ink.color)
                    }
                    .accessibilityIdentifier("ask.picked")
                }
            } else if let typed = answer.typed, !typed.isEmpty {
                Text("“\(typed)”")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ask.typed")
            } else {
                Text("没有回答").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
            }
        } else if isWaiting {
            Text("在输入框上方选，或者直接在输入框里说").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
        } else {
            Text("没有回答").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
        }
    }
}

/// Where a self-review starts in a run (D7): a faint line, not a message — the request itself is sent, not shown.
struct ReviewMarker: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.line.color).frame(width: 14, height: 1)
            Text(text)
                .font(FormoraFont.ui(11))
                .foregroundStyle(Palette.inkFaint.color)
                .lineLimit(2)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .accessibilityIdentifier("review.marker")
    }
}
