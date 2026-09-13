import Foundation

/// read · glob · grep · write · edit (7b, L6). Plain functions over the file system, run off the main actor; every
/// outcome — refusals too — is a `ToolResult` for the model to read.
enum FileTools {
    static let readLineLimit = 2000
    static let lineCharacterLimit = 2000
    static let listLimit = 200
    static let textFileLimit = 10 * 1024 * 1024
    static let grepFileLimit = 2 * 1024 * 1024
    /// Never walked: dependencies and build output, which would drown every search.
    static let skippedFolders: Set<String> = ["node_modules", ".formora-py", ".build", "build", "DerivedData", "Pods"]

    struct Problem: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// `readRoots` / `writeRoots`: outside the project, the Agent's Skill folders (7f, F1–F2). `history`: where a file
    /// is kept as it was before a write or an edit, for 撤销 (10d).
    static func run(_ name: String, arguments json: String, root: URL, readRoots: [URL] = [], writeRoots: [URL] = [],
                    history: URL? = nil) -> ToolResult {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let args = (try? JSONSerialization.jsonObject(with: Data((text.isEmpty ? "{}" : text).utf8))) as? [String: Any] else {
            return .failed("参数不是合法的 JSON 对象：\(json.prefix(200))")
        }
        let sandbox = ProjectSandbox(root: root, readRoots: readRoots, writeRoots: writeRoots)
        do {
            switch name {
            case "read": return try read(args, sandbox)
            case "glob": return try glob(args, sandbox)
            case "grep": return try grep(args, sandbox)
            case "write": return try write(args, sandbox, history: history)
            case "edit": return try edit(args, sandbox, history: history)
            default: return .failed("没有叫 \(name) 的工具")
            }
        } catch let problem as Problem {
            return .failed(problem.message)
        } catch let problem as ProjectSandbox.Problem {
            return .failed(problem.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: read

    static func read(_ args: [String: Any], _ sandbox: ProjectSandbox) throws -> ToolResult {
        let path = try string(args, "path")
        let url = try sandbox.resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Problem("「\(path)」不存在。可以先用 glob 找一下文件")
        }
        if isDirectory.boolValue { return listing(url, sandbox) }
        // A picture goes to the model as itself (7j, V1); one that doesn't decode falls through to the binary refusal.
        if ChatImages.isImage(url), let size = ChatImages.pixelSize(url) {
            var result = ToolResult.done("「\(sandbox.relative(url))」是一张图片（\(size.width)×\(size.height)），图片附在这条结果里。")
            result.images = [url.path]
            return result
        }
        let text = String(decoding: try textData(url, path), as: UTF8.self)
        guard !text.isEmpty else { return .done("（空文件）") }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        let offset = max(1, int(args, "offset") ?? 1)
        let limit = min(max(1, int(args, "limit") ?? readLineLimit), readLineLimit)
        guard offset <= lines.count else { throw Problem("「\(path)」只有 \(lines.count) 行，offset \(offset) 超出了") }
        let end = min(lines.count, offset - 1 + limit)
        let width = String(end).count
        var output = (offset...end).map { number in
            let label = String(number)
            var line = lines[number - 1]
            if line.count > lineCharacterLimit { line = String(line.prefix(lineCharacterLimit)) + "…（这一行太长，后面省略）" }
            return String(repeating: " ", count: width - label.count) + label + "\t" + line
        }.joined(separator: "\n")
        if end < lines.count {
            output += "\n\n（共 \(lines.count) 行，这里是第 \(offset)–\(end) 行；用 offset=\(end + 1) 接着读）"
        }
        return .done(output)
    }

    private static func listing(_ folder: URL, _ sandbox: ProjectSandbox) -> ToolResult {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles])) ?? []
        let named = entries.map { url -> (name: String, isFolder: Bool) in
            (url.lastPathComponent, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        .sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !named.isEmpty else { return .done("「\(sandbox.relative(folder))」是空文件夹") }
        let shown = named.prefix(500).map { $0.isFolder ? $0.name + "/" : $0.name }
        var output = "「\(sandbox.relative(folder))」里有 \(named.count) 项：\n" + shown.joined(separator: "\n")
        if named.count > shown.count { output += "\n…（只列了前 \(shown.count) 项）" }
        return .done(output)
    }

    // MARK: glob

    static func glob(_ args: [String: Any], _ sandbox: ProjectSandbox) throws -> ToolResult {
        let pattern = try string(args, "pattern").trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { throw Problem("pattern 不能为空") }
        let base = try (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map { try sandbox.resolve($0) } ?? sandbox.root
        let regex = try globRegex(pattern)
        let byName = !pattern.contains("/")
        var found: [String] = []
        for url in files(under: base) {
            let subject = byName ? url.lastPathComponent : relative(url, to: base)
            if matches(regex, subject) { found.append(sandbox.relative(url)) }
        }
        guard !found.isEmpty else { return .done("没有找到匹配「\(pattern)」的文件") }
        found.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        var output = found.prefix(listLimit).joined(separator: "\n")
        if found.count > listLimit { output += "\n…（共 \(found.count) 个，只列了前 \(listLimit) 个；把 pattern 写得更具体些）" }
        return .done(output)
    }

    /// `*` within a folder, `**` across folders (`**/` also matching none), `?` one character, `{a,b}` either.
    /// Case-insensitive, like the Mac's own file system.
    static func globRegex(_ pattern: String) throws -> NSRegularExpression {
        let characters = Array(pattern)
        var regex = "^"
        var index = 0
        var inBraces = false
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        regex += "(?:.*/)?"
                        index += 3
                    } else {
                        regex += ".*"
                        index += 2
                    }
                    continue
                }
                regex += "[^/]*"
            case "?": regex += "[^/]"
            case "{": regex += "(?:"; inBraces = true
            case "}" where inBraces: regex += ")"; inBraces = false
            case "," where inBraces: regex += "|"
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        do {
            return try NSRegularExpression(pattern: regex + "$", options: [.caseInsensitive])
        } catch {
            throw Problem("「\(pattern)」不是能用的文件名模式")
        }
    }

    // MARK: grep

    static func grep(_ args: [String: Any], _ sandbox: ProjectSandbox) throws -> ToolResult {
        let pattern = try string(args, "pattern")
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: bool(args, "ignore_case") ? [.caseInsensitive] : [])
        } catch {
            throw Problem("「\(pattern)」不是合法的正则表达式")
        }
        let target = try (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map { try sandbox.resolve($0) } ?? sandbox.root
        let nameFilter = try (args["glob"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map { try (globRegex($0), !$0.contains("/")) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            throw Problem("「\(sandbox.relative(target))」不存在")
        }
        let candidates = isDirectory.boolValue ? files(under: target) : [target]
        var hits: [String] = []
        var total = 0
        for url in candidates {
            if let (filter, byName) = nameFilter, !matches(filter, byName ? url.lastPathComponent : relative(url, to: target)) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= grepFileLimit, let data = try? Data(contentsOf: url), !isBinary(data) else { continue }
            let path = sandbox.relative(url)
            var number = 0
            String(decoding: data, as: UTF8.self).enumerateLines { line, _ in
                number += 1
                guard regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return }
                total += 1
                if hits.count < listLimit {
                    let shown = line.count > 300 ? String(line.prefix(300)) + "…" : line
                    hits.append("\(path):\(number): \(shown)")
                }
            }
        }
        guard !hits.isEmpty else { return .done("没有找到匹配「\(pattern)」的内容") }
        var output = hits.joined(separator: "\n")
        if total > hits.count { output += "\n…（共 \(total) 处，只列了前 \(hits.count) 处；缩小 path 或 glob 再搜）" }
        return .done(output)
    }

    // MARK: write · edit

    /// What a write or an edit will leave in the file, worked out before anything is written (10d): the step itself
    /// writes it, a card waiting for 允许 shows it.
    struct Plan {
        let url: URL
        let exists: Bool
        /// The text there now; `nil` for a new file, or one that isn't text.
        let before: String?
        let after: String
        /// edit: how many places it replaces.
        var replaced = 0
    }

    static func planWrite(_ args: [String: Any], _ sandbox: ProjectSandbox) throws -> Plan {
        let path = try string(args, "path")
        let content = try string(args, "content")
        let url = try sandbox.resolve(path, writing: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { throw Problem("「\(path)」是一个文件夹，不能当文件写") }
        let before = exists ? (try? textData(url, path)).map { String(decoding: $0, as: UTF8.self) } : nil
        return Plan(url: url, exists: exists, before: before, after: content)
    }

    static func planEdit(_ args: [String: Any], _ sandbox: ProjectSandbox) throws -> Plan {
        let path = try string(args, "path")
        let old = try string(args, "old_text")
        let new = try string(args, "new_text")
        let replaceAll = bool(args, "replace_all")
        guard !old.isEmpty else { throw Problem("old_text 不能为空；要写整个文件用 write") }
        guard old != new else { throw Problem("old_text 和 new_text 一样，没有要改的") }
        let url = try sandbox.resolve(path, writing: true)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Problem("「\(path)」不存在；新建文件用 write") }
        let text = String(decoding: try textData(url, path), as: UTF8.self)
        let count = occurrences(of: old, in: text)
        if count == 0 {
            throw Problem("在「\(path)」里没找到 old_text。它必须和文件内容一字不差（包括空格和换行），先用 read 看一下原文")
        }
        if count > 1, !replaceAll {
            throw Problem("old_text 在「\(path)」里出现了 \(count) 次。多带一些前后文让它只出现一次，或者把 replace_all 设为 true")
        }
        var updated = text
        if replaceAll {
            updated = text.replacingOccurrences(of: old, with: new, options: .literal)
        } else if let range = text.range(of: old, options: .literal) {
            updated.replaceSubrange(range, with: new)
        }
        return Plan(url: url, exists: true, before: text, after: updated, replaced: replaceAll ? count : 1)
    }

    static func write(_ args: [String: Any], _ sandbox: ProjectSandbox, history: URL? = nil) throws -> ToolResult {
        let plan = try planWrite(args, sandbox)
        try FileManager.default.createDirectory(at: plan.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plan.after.utf8).write(to: plan.url, options: .atomic)
        let relative = sandbox.relative(plan.url)
        let size = ByteCountFormatter.string(fromByteCount: Int64(plan.after.utf8.count), countStyle: .file)
        // A file written into a Skill's folder isn't the project's: no save card.
        var result = ToolResult(status: .done, output: "已写入 \(relative)（\(plan.exists ? "覆盖了原文件" : "新建")，\(size)）",
                                savedPath: sandbox.contains(plan.url) ? relative : nil, isNewFile: !plan.exists)
        if result.savedPath != nil { result.change = FileHistory.record(plan, history: history) }
        return result
    }

    static func edit(_ args: [String: Any], _ sandbox: ProjectSandbox, history: URL? = nil) throws -> ToolResult {
        let plan = try planEdit(args, sandbox)
        try Data(plan.after.utf8).write(to: plan.url, options: .atomic)
        let relative = sandbox.relative(plan.url)
        var result = ToolResult(status: .done, output: "已修改 \(relative)：替换了 \(plan.replaced) 处", savedPath: relative, isNewFile: false)
        result.change = FileHistory.record(plan, history: history)
        return result
    }

    // MARK: Helpers

    /// A text file's bytes: refused when it is too large or binary.
    private static func textData(_ url: URL, _ path: String) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= textFileLimit else {
            throw Problem("「\(path)」太大了（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))），不能按文本读取")
        }
        let data = try Data(contentsOf: url)
        guard !isBinary(data) else {
            throw Problem("「\(path)」是二进制文件，不能按文本读取。Word、Excel、PPT、PDF 用对应的 Skill 处理")
        }
        return data
    }

    static func isBinary(_ data: Data) -> Bool { data.prefix(8000).contains(0) }

    /// Every file under a folder, hidden ones and dependency folders left out. The `@` list uses it too (7d).
    static func files(under folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 50_000 { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
            } else if values?.isRegularFile == true {
                found.append(url)
            }
        }
        return found
    }

    private static func relative(_ url: URL, to folder: URL) -> String {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    private static func matches(_ regex: NSRegularExpression, _ subject: String) -> Bool {
        regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: .literal, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else { throw Problem("缺少参数 \(key)") }
        return value
    }

    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? Double { return Int(value) }
        return (args[key] as? String).flatMap { Int($0) }
    }

    private static func bool(_ args: [String: Any], _ key: String) -> Bool {
        if let value = args[key] as? Bool { return value }
        return (args[key] as? String)?.lowercased() == "true"
    }
}
