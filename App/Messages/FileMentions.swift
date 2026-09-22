import Foundation

/// A project file a message points at with `@` (7d, D3), as it was when the message was sent.
struct FileMention: Codable, Equatable, Sendable {
    /// Relative to the project folder.
    var path: String
    /// The text the model reads; `nil` for a binary file, or when the message already carries too much.
    var content: String?
    /// Why the content is cut or missing.
    var note: String?
    /// A folder (user 2026-09-22): `content` is its listing, not a file's text. Absent in older data.
    var isFolder: Bool?
}

/// `@` files (D3): like Claude Code, a mentioned text file travels with the message, so the model doesn't spend a
/// turn reading it; big or binary ones go as a path the Agent can `read`.
enum FileMentions {
    static let lineCap = 2_000
    static let characterCap = 60_000
    static let totalCap = 120_000
    /// Files offered in the `@` list at most.
    static let listLimit = 5_000
    /// Entries a folder mention lists at most.
    static let folderLimit = 200
    private static let byteCap = 4 * 1024 * 1024

    /// How the list inserts a path: quoted when it has a space, so the token ends where the path does.
    static func token(for path: String) -> String {
        path.contains(where: \.isWhitespace) ? "@\"\(path)\"" : "@\(path)"
    }

    /// An `@` token: `@"a b.md"`, or `@path` up to a space or sentence punctuation — Chinese runs on after 「，」
    /// without one. An `@` inside a word (an email address) is not one. The composer colours the same tokens.
    static let pattern = #"(?<![^\s])@(?:"([^"\n]+)"|([^\s"，。、；：！？（）【】《》“”‘’,;!?]+))"#

    /// The `@` tokens of a text, in order; a full stop or colon that ends the sentence isn't part of the path.
    static func tokens(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            if match.range(at: 1).location != NSNotFound { return string.substring(with: match.range(at: 1)) }
            guard match.range(at: 2).location != NSNotFound else { return nil }
            let token = string.substring(with: match.range(at: 2))
            let trimmed = String(token.reversed().drop { "，。、,.;；:：!！?？)）]】》'\"".contains($0) }.reversed())
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The tokens that are files of the project, read now. Off the main actor: it reads the disk.
    static func snapshot(_ text: String, root: URL) -> [FileMention] {
        let sandbox = ProjectSandbox(root: root)
        var mentions: [FileMention] = []
        var total = 0
        for token in tokens(in: text) {
            guard let url = try? sandbox.resolve(token) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let path = sandbox.relative(url)
            guard !mentions.contains(where: { $0.path == path }) else { continue }
            if values?.isDirectory == true {
                mentions.append(folderMention(url, path: path))
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= byteCap, let data = try? Data(contentsOf: url) else {
                mentions.append(FileMention(path: path, note: "文件太大，没有带上内容，需要时用 read 分段读"))
                continue
            }
            guard !FileTools.isBinary(data) else {
                mentions.append(FileMention(path: path, note: "二进制文件，不能按文本读；Word、Excel、PPT、PDF 用对应的 Skill 处理"))
                continue
            }
            var content = String(decoding: data, as: UTF8.self)
            var note: String?
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > lineCap {
                content = lines.prefix(lineCap).joined(separator: "\n")
                note = "只带了前 \(lineCap) 行，共 \(lines.count) 行，后面的用 read 读"
            }
            if content.count > characterCap {
                content = String(content.prefix(characterCap))
                note = "只带了前 \(characterCap) 个字符，后面的用 read 读"
            }
            guard total + content.count <= totalCap else {
                mentions.append(FileMention(path: path, note: "这条消息带的文件内容已经够多，这个没有带上，用 read 读"))
                continue
            }
            total += content.count
            mentions.append(FileMention(path: path, content: content, note: note))
        }
        return mentions
    }

    /// A folder as the tree shows it (user 2026-09-22): its direct entries in Finder's order, folders first and marked with
    /// `/`, at most `folderLimit` — never the files' contents, never recursive; `ls` is for the rest.
    static func folderMention(_ url: URL, path: String) -> FileMention {
        guard let entries = try? DirectoryLister.list(url) else {
            return FileMention(path: path, note: "读不了这个文件夹", isFolder: true)
        }
        let shown = entries.prefix(folderLimit).map { path + "/" + $0.name + ($0.isFolder ? "/" : "") }
        let rest = entries.count - shown.count
        return FileMention(path: path, content: shown.joined(separator: "\n"),
                           note: rest > 0 ? "还有 \(rest) 项，用 ls 看" : nil, isFolder: true)
    }

    /// What the model reads after the user's words.
    static func context(_ mentions: [FileMention]) -> String {
        mentions.map { mention in
            guard let content = mention.content else { return "〔@\(mention.path)〕\(mention.note ?? "")" }
            var fence = "```"
            while content.contains(fence) { fence += "`" }
            let note = mention.note.map { "\n（\($0)）" } ?? ""
            let heading = mention.isFolder == true ? "〔@\(mention.path)/ 的目录〕" : "〔@\(mention.path) 的内容〕"
            return "\(heading)\n\(fence)\n\(content)\n\(fence)\(note)"
        }.joined(separator: "\n\n")
    }

    /// A mention in a bubble is a link that opens the file in 文件.
    static func link(_ path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "formora-file"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    static func path(fromLink url: URL) -> String? {
        guard url.scheme == "formora-file" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value
    }

    /// The project's files for the `@` list: relative paths, hidden and dependency folders left out.
    static func projectFiles(root: URL) -> [String] {
        let sandbox = ProjectSandbox(root: root)
        return FileTools.files(under: sandbox.root).prefix(listLimit).map { sandbox.relative($0) }.sorted()
    }
}
