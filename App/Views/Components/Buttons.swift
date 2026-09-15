import SwiftUI

/// `.btn` from the mockup: 36pt pill, Sora 12.5/600. `.primary` is the accent fill; `.ghost` is text only;
/// `.destructive` puts the whole button (text, icon, border) in the alert color — rule R1 (user 2026-09-11).
/// Disabled buttons fade to 35% as a whole — the fill stays the same (design spec §4.1).
struct FormoraButtonStyle: ButtonStyle {
    enum Kind { case standard, primary, ghost, destructive }

    var kind: Kind = .standard
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FormoraButtonBody(configuration: configuration, kind: kind, fillsWidth: fillsWidth)
    }
}

private struct FormoraButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: FormoraButtonStyle.Kind
    let fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(FormoraFont.ui(12.5, weight: 600))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 17)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 36)
            .background(Capsule().fill(background))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(opacity)
            .onHover { isHovering = $0 }
    }

    private var active: Bool { isEnabled && (isHovering || configuration.isPressed) }

    private var foreground: Color {
        switch kind {
        case .standard: Palette.ink.color
        case .primary: Palette.accentInk.color
        case .ghost: active ? Palette.ink.color : Palette.inkMuted.color
        case .destructive: Palette.alert.color
        }
    }

    private var background: Color {
        switch kind {
        case .standard: active ? Palette.surfaceRaised2.color : Palette.surfaceRaised.color
        case .primary: Palette.accent.color
        case .ghost: .clear
        case .destructive: active ? Palette.alertSoft.color : Palette.surfaceRaised.color
        }
    }

    private var border: Color {
        switch kind {
        case .standard: Palette.lineStrong.color
        case .primary: Palette.accent.color
        case .ghost: .clear
        case .destructive: Palette.alertLine.color
        }
    }

    private var opacity: Double {
        if !isEnabled { return 0.35 }
        return kind == .primary && active ? 0.92 : 1
    }
}

/// `.icon-action`: 30pt round icon button, 15pt icon; the fill only appears on hover. Disabled at 32%.
struct IconActionButton: View {
    let icon: SVGIcon
    let label: String
    var identifier: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 15)
                .frame(width: 30, height: 30)
                .foregroundStyle(isHovering && isEnabled ? Palette.ink.color : Palette.inkMuted.color)
                .background(Circle().fill(isHovering && isEnabled ? Palette.surfaceRaised2.color : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.32)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? label)
    }
}

/// `.status-line`: a 6pt dot and 10.5pt text in the same color.
struct StatusLine: View {
    enum Tone { case neutral, success, alert }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 6, height: 6)
            Text(text).font(FormoraFont.ui(10.5))
        }
        .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .neutral: Palette.inkFaint.color
        case .success: Palette.success.color
        case .alert: Palette.alert.color
        }
    }
}

/// A copy icon before a command or a code block (user 2026-09-15): the text goes to the clipboard, 「已复制」 is the toast.
struct CopyIcon: View {
    let text: String
    let copy: (String) -> Void
    var label = "复制命令"

    @State private var isHovering = false

    var body: some View {
        Button { copy(text) } label: {
            IconView(Icons.copy, size: 11)
                .foregroundStyle(isHovering ? Palette.ink.color : Palette.inkFaint.color)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("copy.command")
    }
}
