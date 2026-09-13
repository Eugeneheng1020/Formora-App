import AppKit
import CoreText
import SwiftUI

enum FontFamily: String, CaseIterable, Sendable {
    /// Text people read: titles, body, labels.
    case sora = "Sora"
    /// Data people check: timestamps, token counts, file and project names, ids.
    case jetBrainsMono = "JetBrains Mono"

    var resourceName: String {
        switch self {
        case .sora: "Sora-Variable"
        case .jetBrainsMono: "JetBrainsMono-Variable"
        }
    }
}

enum FontRegistry {
    /// Registers the bundled fonts for this process. Calling it again is harmless.
    /// Returns the families that could not be registered (empty means success).
    @discardableResult
    static func registerBundledFonts(in bundle: Bundle = .main) -> [FontFamily] {
        FontFamily.allCases.filter { family in
            guard let url = bundle.url(forResource: family.resourceName, withExtension: "ttf", subdirectory: "Fonts") else {
                return true
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return false }
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            return code != CTFontManagerError.alreadyRegistered.rawValue
        }
    }
}

enum FormoraFont {
    /// OpenType tag 'wght'.
    static let wghtAxis: UInt32 = 0x7767_6874

    /// Each font is built once per family, size and weight (9a): building one from its descriptor showed up in every
    /// redraw of every section.
    private struct Key: Hashable {
        let family: FontFamily
        let size: CGFloat
        let weight: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var nsFonts: [Key: NSFont] = [:]
    nonisolated(unsafe) private static var fonts: [Key: Font] = [:]

    /// `weight` is the CSS weight number used in the design (400, 500, 600, 700, 800).
    static func nsFont(_ family: FontFamily, size: CGFloat, weight: Int) -> NSFont {
        let key = Key(family: family, size: size, weight: weight)
        lock.lock()
        defer { lock.unlock() }
        if let font = nsFonts[key] { return font }
        let font = makeNSFont(family, size: size, weight: weight)
        nsFonts[key] = font
        return font
    }

    private static func font(_ family: FontFamily, size: CGFloat, weight: Int) -> Font {
        let key = Key(family: family, size: size, weight: weight)
        lock.lock()
        let kept = fonts[key]
        lock.unlock()
        if let kept { return kept }
        let made = Font(nsFont(family, size: size, weight: weight) as CTFont)
        lock.lock()
        fonts[key] = made
        lock.unlock()
        return made
    }

    private static func makeNSFont(_ family: FontFamily, size: CGFloat, weight: Int) -> NSFont {
        let variationKey = NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family.rawValue,
            variationKey: [NSNumber(value: wghtAxis): NSNumber(value: weight)],
        ])
        if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family.rawValue {
            return font
        }
        let fallbackWeight: NSFont.Weight = weight >= 700 ? .bold : weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular
        return family == .jetBrainsMono
            ? .monospacedSystemFont(ofSize: size, weight: fallbackWeight)
            : .systemFont(ofSize: size, weight: fallbackWeight)
    }

    static func ui(_ size: CGFloat, weight: Int = 400) -> Font {
        font(.sora, size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: Int = 400) -> Font {
        font(.jetBrainsMono, size: size, weight: weight)
    }
}
