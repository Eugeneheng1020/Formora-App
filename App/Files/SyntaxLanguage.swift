/// File extension → highlight.js language id. Explicit rather than auto-detected (auto-detection is
/// unreliable on short files); anything unmapped is shown as plain text, never guessed.
enum SyntaxLanguage {
    private static let map: [String: String] = [
        "swift": "swift",
        "py": "python", "pyw": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "json": "json", "jsonc": "json",
        "xml": "xml", "plist": "xml", "svg": "xml", "html": "xml", "htm": "xml", "xib": "xml", "storyboard": "xml",
        "yml": "yaml", "yaml": "yaml",
        "md": "markdown", "markdown": "markdown",
        "sh": "bash", "bash": "bash", "zsh": "bash", "command": "bash",
        "css": "css", "scss": "scss", "less": "less",
        "sql": "sql",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "go": "go",
        "rs": "rust",
        "rb": "ruby",
        "php": "php",
        "m": "objectivec", "mm": "objectivec",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "cs": "csharp",
        "lua": "lua",
        "pl": "perl", "pm": "perl",
        "r": "r",
        "ini": "ini", "cfg": "ini", "conf": "ini", "toml": "ini", "properties": "ini",
        "diff": "diff", "patch": "diff",
        "mk": "makefile",
        "graphql": "graphql", "gql": "graphql",
        "vb": "vbnet",
    ]

    /// Extension-less files recognized by name.
    private static let names: [String: String] = [
        "makefile": "makefile", "dockerfile": "bash", "gemfile": "ruby", "podfile": "ruby",
    ]

    static var allMappedIDs: Set<String> { Set(map.values).union(names.values) }

    static func id(forFileName fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty { return names[fileName.lowercased()] }
        return map[ext]
    }
}

import Foundation
