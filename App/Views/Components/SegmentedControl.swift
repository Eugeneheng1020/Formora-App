import SwiftUI

/// `.segmented`: the mockup's shared pill switch (model source, MCP tools, Memory scope; here also the HTML
/// 预览/源码 switch). Container 3pt padding, 2pt gap on `--surface-raised`; the chosen pill is
/// `--surface-raised-2`, ink, semibold. Callers own the outer margins, as in the mockup.
struct SegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var identifier: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(FormoraFont.ui(11.5, weight: isOn ? 600 : 400))
                        .foregroundStyle(isOn ? Palette.ink.color : Palette.inkMuted.color)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 13)
                        .background(Capsule().fill(isOn ? Palette.surfaceRaised2.color : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(option.value)")
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.surfaceRaised.color))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
