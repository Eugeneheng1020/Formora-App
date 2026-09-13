import SwiftUI

/// One toast at a time, top-right, auto-dismissed (design spec §4.1: 3 s by default, 2 s for "saved").
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let note: String?
        let isError: Bool
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    func show(_ title: String, note: String? = nil, isError: Bool = false, seconds: Double = 3) {
        let toast = Toast(title: title, note: note, isError: isError)
        current = toast
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissal?.cancel()
        current = nil
    }
}

struct ToastHost: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let toast = center.current {
                ToastView(toast: toast)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: 330)
        .padding(.top, 18)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: center.current)
        .allowsHitTesting(false)
    }
}

private struct ToastView: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconView(toast.isError ? Icons.alertCircle : Icons.check, size: 16)
                .foregroundStyle(toast.isError ? Palette.alert.color : Palette.success.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                if let note = toast.note {
                    Text(note).font(FormoraFont.ui(10.5)).foregroundStyle(Palette.inkMuted.color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .softShadow()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toast")
    }
}
