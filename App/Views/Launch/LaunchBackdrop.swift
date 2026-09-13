import SwiftUI

enum LaunchMetrics {
    /// The launch window is the mockup's card itself (user 2026-09-02): 460 wide, one size for every screen.
    static let windowSize = CGSize(width: 460, height: 560)
    static let horizontalPadding: CGFloat = 36
    static let verticalPadding: CGFloat = 40
}

/// The page backdrop from `launch-flow-v1.html` (`.launch-screen`), drawn inside the card-sized window:
/// `--ground` with two soft accent glows — never flat black (user 2026-09-02).
struct LaunchBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Palette.ground.color
                glow(center: UnitPoint(x: 0.20, y: 0.15), stop: 0.45, in: geometry.size)
                glow(center: UnitPoint(x: 0.82, y: 0.78), stop: 0.40, in: geometry.size)
            }
        }
        .ignoresSafeArea()
    }

    /// CSS `radial-gradient(circle at X Y, accent-soft, transparent S%)`: the percentage is of the
    /// distance to the farthest corner.
    private func glow(center: UnitPoint, stop: CGFloat, in size: CGSize) -> some View {
        let cx = center.x * size.width, cy = center.y * size.height
        let farthest = [(0.0, 0.0), (size.width, 0.0), (0.0, size.height), (size.width, size.height)]
            .map { hypot($0.0 - cx, $0.1 - cy) }
            .max() ?? 0
        return RadialGradient(colors: [Palette.accentSoft.color, Palette.accentSoft.color.opacity(0)],
                              center: center, startRadius: 0, endRadius: farthest * stop)
    }
}
