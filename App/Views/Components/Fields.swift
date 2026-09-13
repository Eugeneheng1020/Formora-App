import SwiftUI

/// Input metrics. `.form` is the launch flow's `.form-input` (13.5pt, radius 10, 42 tall);
/// `.detail` is `.detail-input` used in dialogs and detail panes (12pt, radius 8, 36 tall).
enum FieldMetrics {
    case form
    case detail

    var fontSize: CGFloat { self == .form ? 13.5 : 12 }
    var cornerRadius: CGFloat { self == .form ? 10 : 8 }
    var height: CGFloat { self == .form ? 42 : 36 }
    var horizontalPadding: CGFloat { self == .form ? 13 : 11 }
}

private struct FieldChrome: ViewModifier {
    let metrics: FieldMetrics
    let isFocused: Bool
    let isInvalid: Bool

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .strokeBorder(isInvalid ? Palette.alert.color : isFocused ? Palette.accent.color : Palette.lineStrong.color,
                                  lineWidth: 1)
            )
    }
}

struct FormoraTextField: View {
    let placeholder: String
    @Binding var text: String
    var metrics: FieldMetrics = .form
    var isInvalid = false
    var identifier: String

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(FormoraFont.ui(metrics.fontSize))
            .foregroundStyle(Palette.ink.color)
            .focused($isFocused)
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier(identifier)
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(FormoraFont.ui(metrics.fontSize))
                        .foregroundStyle(Palette.inkFaint.color)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(height: metrics.height)
            .modifier(FieldChrome(metrics: metrics, isFocused: isFocused, isInvalid: isInvalid))
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
    }
}

struct FormoraTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat
    var metrics: FieldMetrics = .form
    var identifier: String

    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .font(FormoraFont.ui(metrics.fontSize))
            .foregroundStyle(Palette.ink.color)
            .lineSpacing(4)
            .focused($isFocused)
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier(identifier)
            .padding(.horizontal, metrics.horizontalPadding - 5)
            .padding(.vertical, 8)
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(FormoraFont.ui(metrics.fontSize))
                        .foregroundStyle(Palette.inkFaint.color)
                        .padding(.horizontal, metrics.horizontalPadding)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            .modifier(FieldChrome(metrics: metrics, isFocused: isFocused, isInvalid: false))
    }
}

/// `.form-label` (launch flow) — 12.5/600 with an optional 「选填」 pill.
struct FormLabel: View {
    let text: String
    var optional = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
            if optional {
                Text("选填")
                    .font(FormoraFont.mono(10, weight: 500))
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            }
        }
        .padding(.bottom, 8)
    }
}

/// `.inline-error`: 10.5pt alert text right under the field it explains.
struct InlineError: View {
    let text: String
    var identifier = "inlineError"

    var body: some View {
        Text(text)
            .font(FormoraFont.ui(10.5))
            .foregroundStyle(Palette.alert.color)
            .padding(.top, 5)
            .accessibilityIdentifier(identifier)
    }
}
