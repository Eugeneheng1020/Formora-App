import Foundation

private final class PreviewBundleToken {}

/// The bundled preview assets (`Resources/Preview/`), read once.
enum PreviewResources {
    private static let bundle = Bundle(for: PreviewBundleToken.self)

    /// highlight.js 11.10.0 (BSD-3-Clause), common-languages build.
    static let highlightScript: String = load("highlight.min", "js")
    /// marked 14.1.3 (MIT).
    static let markedScript: String = load("marked.min", "js")
    /// highlight.js theme in the Formora palette.
    static let syntaxTheme: String = load("formora-syntax", "css")

    private static func load(_ name: String, _ ext: String) -> String {
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Preview"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
