import Foundation

/// 10c: the project's own instruction files — what the user already wrote for Codex, Claude Code, Gemini or Copilot —
/// read at the project folder into every request's system prompt (Codex `core/src/agents_md.rs`; omp
/// `docs/context-files.md`). Being in the system prompt, they hold however long the conversation grows.
enum ContextFiles {
    struct File: Equatable, Sendable {
        /// Relative to the project folder.
        let path: String
        let text: String
    }

    /// In this order. The user's own files elsewhere (`~/.claude/CLAUDE.md` …) aren't read: they are that person's
    /// habits for a coding tool, not this project's conventions.
    static let names = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "GEMINI.md", ".gemini/GEMINI.md", ".github/copilot-instructions.md"]
    /// Codex's local override: when it has something, it stands in for AGENTS.md.
    static let override = "AGENTS.override.md"
    /// Codex's default `project_doc_max_bytes`.
    static let maxBytes = 32 * 1024

    static func load(root: URL) -> [File] {
        var files: [File] = []
        var used = 0
        for name in names {
            let path = name == "AGENTS.md" && hasText(root.appendingPathComponent(override)) ? override : name
            guard let raw = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty says nothing; CLAUDE.md is often AGENTS.md again (a link, or a copy): once is enough.
            guard !text.isEmpty, !files.contains(where: { $0.text == text }) else { continue }
            let room = maxBytes - used
            guard room > 0 else { break }
            if text.utf8.count > room {
                files.append(File(path: path, text: String(decoding: Array(text.utf8.prefix(room)), as: UTF8.self)
                                  + "\n…（说明文件合计超过 \(maxBytes / 1024) KB，后面的没有读）"))
                break
            }
            files.append(File(path: path, text: text))
            used += text.utf8.count
        }
        return files
    }

    /// The system prompt's section: the files as they are, each marked with its path.
    static func section(_ files: [File]) -> String? {
        guard !files.isEmpty else { return nil }
        let bodies = files.map { "<project-instructions path=\"\($0.path)\">\n\($0.text)\n</project-instructions>" }
        return "用户为这个项目写的说明文件（项目的约定，照着做；和用户在对话里说的冲突时，以用户说的为准）：\n"
            + bodies.joined(separator: "\n")
    }

    private static func hasText(_ url: URL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
