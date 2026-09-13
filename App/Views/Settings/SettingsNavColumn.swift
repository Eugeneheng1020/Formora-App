import SwiftUI

/// 设置's list column: the categories as `.conv-item.settings-cat` rows — 34pt icon tile + name, vertically
/// centred. No group titles (user 2026-09-05, deviation D9) and no search box (design spec §5).
struct SettingsNavColumn: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(FormoraFont.ui(19, weight: 700))
                .tracking(-0.19)
                .foregroundStyle(Palette.ink.color)
                .frame(height: 26, alignment: .leading)
                .accessibilityIdentifier("list.title")
                // `.list-title-row` margin 14 + the empty `.filter-tabs` row's 10pt bottom padding.
                .padding(.bottom, 24)
                .padding(.top, 16)
                .padding(.horizontal, 18)

            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { category in
                    SettingsNavRow(category: category, isSelected: state.settingsCategory == category) {
                        state.settingsCategory = category
                    }
                }
            }
            .padding(.top, 2)
            .padding(.horizontal, 8)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.nav")

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.color)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line.color).frame(width: 1) }
    }

    private func move(_ delta: Int) {
        let all = SettingsCategory.allCases
        guard let index = all.firstIndex(of: state.settingsCategory) else { return }
        state.settingsCategory = all[min(max(index + delta, 0), all.count - 1)]
    }
}

private struct SettingsNavRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconView(category.icon, size: 17)
                    .foregroundStyle(isSelected ? Palette.accent.color : Palette.inkMuted.color)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Palette.accentSoft.color : Palette.surfaceRaised2.color))
                Text(category.title)
                    .font(FormoraFont.ui(13.5, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Palette.lineStrong.color : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.nav.\(category.rawValue)")
    }

    private var background: Color {
        if isSelected { return Palette.surfaceRaised2.color }
        return isHovering ? Palette.surfaceRaised.color : .clear
    }
}
