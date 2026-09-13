import SwiftUI

/// Draws an `SVGIcon` at `size` points using the current foreground style, round caps and joins.
struct IconView: View {
    private let icon: SVGIcon
    private let size: CGFloat

    init(_ icon: SVGIcon, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / icon.viewBox.width
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: -icon.viewBox.minX, y: -icon.viewBox.minY)
            for layer in icon.layers {
                let path = layer.path.applying(transform)
                switch layer.paint {
                case .fill:
                    context.fill(path, with: .foreground)
                case .stroke(let width):
                    context.stroke(path, with: .foreground,
                                   style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
