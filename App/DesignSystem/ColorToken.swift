import AppKit
import SwiftUI

/// One sRGB color from the design spec, kept as integers so tests can compare it exactly.
struct ColorToken: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let opacity: Double

    init(_ hex: UInt32, opacity: Double = 1) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
        self.opacity = opacity
    }

    var hexString: String { String(format: "#%02X%02X%02X", red, green, blue) }

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: opacity)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: opacity)
    }
}
