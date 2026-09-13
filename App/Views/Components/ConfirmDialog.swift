import SwiftUI

/// A compact centred dialog with one destructive choice: kicker, title, what happens, 取消 + the action.
/// The scrim doesn't close it; Esc is 取消.
struct ConfirmDialog: View {
    let kicker: String
    let title: String
    let message: String
    var cancelTitle = "取消"
    let confirmTitle: String
    let identifier: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(kicker.uppercased()).font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
                    Text(title).font(FormoraFont.ui(18, weight: 700)).foregroundStyle(Palette.ink.color)
                        .accessibilityIdentifier("\(identifier).title")
                    Text(message).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 22)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                Rectangle().fill(Palette.line.color).frame(height: 1)
                HStack(spacing: 9) {
                    Spacer(minLength: 0)
                    Button(cancelTitle, action: onCancel)
                        .buttonStyle(FormoraButtonStyle(kind: .ghost))
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("\(identifier).cancel")
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(FormoraButtonStyle(kind: .destructive))
                        .accessibilityIdentifier("\(identifier).confirm")
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
            }
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .modalShadow()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }
}
