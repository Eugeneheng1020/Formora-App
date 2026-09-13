import SwiftUI

/// 10i: under a side conversation's header — what it is, and the way back.
struct SideBanner: View {
    let back: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("岔开问一句").font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                Text("这里的问答不会进主对话，Agent 只看、不改；回到主对话时这里会清掉。")
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(action: back) {
                Label { Text("回到主对话") } icon: { IconView(Icons.chevronLeft, size: 12) }
            }
            .buttonStyle(FormoraButtonStyle())
            .accessibilityIdentifier("side.back")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 24)
        .background(Palette.accentSoft.color)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side.banner")
    }
}
