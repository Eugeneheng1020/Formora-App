import AppKit

extension SVGIcon {
    /// A template image of the icon for native menus (context menus show a `Label`'s image), drawn from the
    /// same paths as `IconView` so a menu item and its on-screen twin are the same glyph.
    func templateImage(size: CGFloat = 15) -> NSImage {
        let box = viewBox
        let layers = layers
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / box.width
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for layer in layers {
                context.addPath(layer.path.cgPath)
                switch layer.paint {
                case .fill:
                    context.fillPath()
                case .stroke(let width):
                    context.setLineWidth(width)
                    context.strokePath()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
