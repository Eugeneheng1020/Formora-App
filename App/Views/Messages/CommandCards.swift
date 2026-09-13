import SwiftUI

/// A command's output (7d, D2; mockup `.cmd-card`): one-off — it sits under the thread until the next message or ×,
/// and never becomes history (spec §9.8c: command output is not the history).
struct CommandCard: Equatable, Identifiable {
    struct Row: Equatable {
        let name: String
        let note: String
    }

    enum Body: Equatable {
        case rows([Row])
        case mono(String)
        case text(String)
        /// The conversation's plan, drawn from the conversation as it changes (D4).
        case plan
        /// `/cost` (7e, E6), likewise live.
        case usage
        /// `/memory` (7f, F4): read-only, as the spec keeps it.
        case memory
    }

    let id = UUID()
    let kicker: String
    let title: String
    let body: Body
}

struct CommandCardView<Live: View>: View {
    let card: CommandCard
    let close: () -> Void
    /// The body of a live card (`.plan`, `.usage`), drawn from the conversation.
    @ViewBuilder var live: () -> Live

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(card.title)
                    .font(FormoraFont.ui(12.5, weight: 700))
                    .foregroundStyle(Palette.ink.color)
                Spacer(minLength: 12)
                Text(card.kicker.uppercased())
                    .font(FormoraFont.mono(10))
                    .foregroundStyle(Palette.inkFaint.color)
                IconActionButton(icon: Icons.close, label: "关闭", identifier: "commandCard.close", action: close)
            }
            .padding(.bottom, 9)
            content
        }
        .padding(.vertical, 12)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("commandCard")
    }

    @ViewBuilder private var content: some View {
        switch card.body {
        case .rows(let rows):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(rows, id: \.name) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.name)
                            .font(FormoraFont.mono(11.5))
                            .foregroundStyle(Palette.ink.color)
                            .frame(width: 96, alignment: .leading)
                        Text(row.note)
                            .font(FormoraFont.ui(12))
                            .foregroundStyle(Palette.inkMuted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.trailing, 6)
        case .mono(let text):
            Text(text)
                .font(FormoraFont.mono(11.5))
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 6)
        case .text(let text):
            Text(text)
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 6)
        case .plan, .usage, .memory:
            live()
        }
    }
}
