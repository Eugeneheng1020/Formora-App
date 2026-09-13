import SwiftUI

/// 10g: where a watched rule stopped the reply — in the Agent's frame, before what it wrote instead.
struct RuleMarker: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            IconView(Icons.alertCircle, size: 12).foregroundStyle(Palette.accent.color)
            Text(text)
                .font(FormoraFont.ui(11.5))
                .foregroundStyle(Palette.inkMuted.color)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Palette.accentSoft.color))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("rule.marker")
    }
}
