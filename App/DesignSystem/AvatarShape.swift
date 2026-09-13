import SwiftUI

/// Every avatar in Formora is a rounded square (user decision 2026-09-07, deviation D2 — the mockup draws circles).
/// The corner radius scales with the avatar so small and large avatars read as the same shape.
struct AvatarShape: InsettableShape {
    static let cornerRatio: CGFloat = 0.28

    static func cornerRadius(forSize size: CGFloat) -> CGFloat {
        (size * cornerRatio).rounded()
    }

    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = max(0, Self.cornerRadius(forSize: min(rect.width, rect.height)) - insetAmount)
        return Path(roundedRect: rect.insetBy(dx: insetAmount, dy: insetAmount), cornerRadius: radius, style: .continuous)
    }

    func inset(by amount: CGFloat) -> AvatarShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
