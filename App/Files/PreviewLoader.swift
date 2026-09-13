import Foundation
import UniformTypeIdentifiers

/// How a file is shown.
enum PreviewKind: Equatable, Sendable {
    case markdown
    case html
    case structured(ConfigFormat)
    case code(languageID: String)
    case plainText
    case quickLook
    /// Unknown extension: decided after reading (text → plain text, otherwise an info card).
    case sniff

    enum ConfigFormat: Equatable, Sendable { case json, xml, plist }

    private static let quickLookExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf", "rtfd",
        "mov", "mp4", "m4v", "mp3", "m4a", "wav", "aiff", "aif",
    ]
    private static let plainTextExtensions: Set<String> = ["txt", "text", "log", "csv", "tsv", "env", "gitignore", "example"]

    static func forFile(named name: String) -> PreviewKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return .markdown
        case "html", "htm": return .html
        case "json": return .structured(.json)
        case "xml": return .structured(.xml)
        case "plist": return .structured(.plist)
        default: break
        }
        if quickLookExtensions.contains(ext) { return .quickLook }
        if plainTextExtensions.contains(ext) { return .plainText }
        if let id = SyntaxLanguage.id(forFileName: name) { return .code(languageID: id) }
        return .sniff
    }
}

struct FileFacts: Equatable, Sendable {
    let name: String
    let typeDescription: String
    let byteCount: Int
    let modified: Date?
}

/// How an HTML file is shown: the live page, or its highlighted source (user request 2026-09-11).
enum HTMLViewMode: String, CaseIterable, Sendable {
    case rendered, source
}

enum PreviewContent: Equatable, Sendable {
    /// A generated, self-contained HTML document (Markdown or code).
    case document(html: String)
    /// A real HTML file rendered live.
    case webPage(URL)
    case structured(ConfigNode)
    case quickLook(URL)
    case info(FileFacts, InfoReason)

    enum InfoReason: Equatable, Sendable {
        case empty
        case tooLarge(limit: Int)
        case binary
        case unreadable
    }
}

/// Reads a file (off the main actor) and decides what to show. Never writes.
enum PreviewLoader {
    /// Text files above this show an info card instead of being loaded.
    static let textLimit = 5_000_000
    /// Text above this is shown without syntax highlighting, to stay fast.
    static let highlightLimit = 512_000

    static func load(_ url: URL, projectRoot: URL?, htmlView: HTMLViewMode = .rendered) -> PreviewContent {
        let facts = self.facts(for: url)
        let kind = PreviewKind.forFile(named: url.lastPathComponent)

        if kind == .quickLook { return .quickLook(url) }
        if facts.byteCount > textLimit { return .info(facts, .tooLarge(limit: textLimit)) }
        if kind == .html, htmlView == .rendered { return .webPage(url) }

        guard let data = try? Data(contentsOf: url) else { return .info(facts, .unreadable) }
        if data.isEmpty { return .info(facts, .empty) }

        switch kind {
        case .structured(let format):
            let parsed: ConfigNode? = switch format {
            case .json: ConfigNode.parseJSON(data)
            case .xml: ConfigNode.parseXML(data)
            case .plist: ConfigNode.parsePropertyList(data)
            }
            if let parsed { return .structured(parsed) }
            // A broken file still gets something to look at: its highlighted source.
            guard let text = decodeText(data) else { return .info(facts, .binary) }
            return code(text, languageID: format == .json ? "json" : "xml")
        case .markdown:
            guard let text = decodeText(data) else { return .info(facts, .binary) }
            return .document(html: MarkdownDocument.build(source: text, fileURL: url, projectRoot: projectRoot))
        case .code(let id):
            guard let text = decodeText(data) else { return .info(facts, .binary) }
            return code(text, languageID: id)
        case .plainText, .sniff:
            guard let text = decodeText(data) else { return .info(facts, .binary) }
            return code(text, languageID: nil)
        case .html:
            guard let text = decodeText(data) else { return .info(facts, .binary) }
            return code(text, languageID: "xml")
        case .quickLook:
            return .info(facts, .unreadable)
        }
    }

    private static func code(_ text: String, languageID: String?) -> PreviewContent {
        let id = text.utf8.count > highlightLimit ? nil : languageID
        return .document(html: CodeDocument.build(source: text, languageID: id))
    }

    /// UTF-8 only, and a NUL byte in the first 8 KB means binary even if it happens to decode.
    static func decodeText(_ data: Data) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func facts(for url: URL) -> FileFacts {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey])
        return FileFacts(name: url.lastPathComponent,
                         typeDescription: values?.contentType?.localizedDescription ?? "文件",
                         byteCount: values?.fileSize ?? 0,
                         modified: values?.contentModificationDate)
    }
}
