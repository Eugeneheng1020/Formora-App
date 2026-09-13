import SwiftUI

/// CSS box-shadows from design spec §1, approximated (SwiftUI shadows have no spread; blur ≈ 2 × radius).
extension View {
    /// `--shadow-soft`: panels, menus, toasts.
    func softShadow() -> some View {
        shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            .shadow(color: .black.opacity(0.75), radius: 12, y: 10)
    }

    /// `--shadow-modal`: dialogs.
    func modalShadow() -> some View {
        shadow(color: .black.opacity(0.88), radius: 26, y: 22)
    }
}
