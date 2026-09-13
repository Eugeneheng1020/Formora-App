import SwiftUI

/// `.search`: pill, `--surface-raised`, 8/14 padding, 15pt magnifier, 13pt input. The accent border shows focus.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var identifier: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            IconView(Icons.search, size: 15).foregroundStyle(Palette.inkMuted.color)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(FormoraFont.ui(13))
                .foregroundStyle(Palette.ink.color)
                .focused($isFocused)
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier(identifier)
                .background(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder).font(FormoraFont.ui(13)).foregroundStyle(Palette.inkFaint.color).allowsHitTesting(false)
                    }
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    IconView(Icons.close, size: 11).foregroundStyle(Palette.inkFaint.color).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        // The mockup's 8pt padding around a 13px input line box renders 36 tall; Sora's own line height is shorter.
        .frame(height: 36)
        .background(Capsule().fill(Palette.surfaceRaised.color))
        .overlay(Capsule().strokeBorder(isFocused ? Palette.accent.color : .clear, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
    }
}
