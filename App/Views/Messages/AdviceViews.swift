import SwiftUI

/// 10k: `/review`'s graded review — the verdict, a few sentences, the problems from P0 down (omp's reviewer).
struct ReviewCard: View {
    let review: Advisor.Review

    static func color(_ level: Int) -> Color {
        switch level {
        case 0: Palette.alert.color
        case 1: Palette.accent.color
        case 2: Palette.inkMuted.color
        default: Palette.inkFaint.color
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                IconView(Icons.eye, size: 12).foregroundStyle(Palette.inkMuted.color)
                Text("旁审 · 审查").font(FormoraFont.ui(11, weight: 600)).foregroundStyle(Palette.inkMuted.color)
                Text(review.passes ? "可以交付" : "需要改")
                    .font(FormoraFont.ui(11, weight: 600))
                    .foregroundStyle(review.passes ? Palette.success.color : Palette.alert.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(review.passes ? Palette.successSoft.color : Palette.alertSoft.color))
                    .accessibilityIdentifier("review.verdict")
            }
            Text(review.summary)
                .font(FormoraFont.ui(12.5))
                .foregroundStyle(Palette.ink.color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(Array(review.findings.enumerated()), id: \.offset) { _, finding in
                HStack(alignment: .top, spacing: 9) {
                    Text(finding.label)
                        .font(FormoraFont.mono(10.5))
                        .foregroundStyle(Self.color(finding.level))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Self.color(finding.level), lineWidth: 1))
                        .help(finding.meaning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title + (finding.place.map { "  ·  \($0)" } ?? ""))
                            .font(FormoraFont.ui(12.5, weight: 600))
                            .foregroundStyle(Palette.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                        if !finding.detail.isEmpty {
                            Text(finding.detail)
                                .font(FormoraFont.ui(12))
                                .foregroundStyle(Palette.inkMuted.color)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("review.finding")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.card")
    }
}

/// 10h: a 旁审 note in the Agent's frame — what the watcher said, and how strongly.
struct AdviceCard: View {
    let severity: Advisor.Severity
    let text: String

    private var color: Color {
        switch severity {
        case .nit: Palette.inkMuted.color
        case .concern: Palette.accent.color
        case .blocker: Palette.alert.color
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                IconView(Icons.eye, size: 12).foregroundStyle(color)
                Text("旁审 · \(severity.label)").font(FormoraFont.ui(11, weight: 600)).foregroundStyle(color)
            }
            Text(text)
                .font(FormoraFont.ui(12.5))
                .foregroundStyle(Palette.ink.color)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(color).frame(width: 3).padding(.vertical, 7).padding(.leading, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("advice.card")
    }
}
