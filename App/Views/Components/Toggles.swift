import SwiftUI

/// `.switch`: 38 × 22 track; on = accent-soft track with an accent border and knob. The label next to it names
/// what it controls and never flips with the state (design spec §4.1).
struct FormoraSwitch: View {
    @Binding var isOn: Bool
    var isEnabled = true
    let label: String
    let identifier: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Palette.accentSoft.color : Palette.surfaceRaised2.color)
                Capsule().strokeBorder(isOn ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1)
                Circle()
                    .fill(isOn ? Palette.accent.color : Palette.inkFaint.color)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 2)
            }
            .frame(width: 38, height: 22)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(identifier)
    }
}

/// `.check-box`: 18pt, radius 5; checked = accent fill with a dark tick.
struct CheckBox: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isOn ? Palette.accent.color : Palette.surfaceRaised.color)
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isOn ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1)
            if isOn { IconView(Icons.check, size: 12).foregroundStyle(Palette.accentInk.color) }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
