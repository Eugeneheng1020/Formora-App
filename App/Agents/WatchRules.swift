import Foundation

/// 10g: rules that stay out of the prompt until the model breaks one (omp's time-traveling stream rules: README §04,
/// `docs/ttsr-injection-lifecycle.md`). A rule is a Markdown file in the project's `.formora/rules/` (or omp's
/// `.omp/rules/`) whose front matter has a `condition` — a regular expression. While a reply streams, its words and
/// its calls' arguments are watched; a match stops the reply there, what it wrote goes, the rule is handed to the
/// model, and the call goes again. Once per conversation: the reminder stays in its history.
enum WatchRules {
    struct Rule: Equatable, Sendable {
        let name: String
        /// Relative to the project folder.
        let path: String
        let conditions: [String]
        let watchesText: Bool
        /// Whose arguments are watched: `nil`, every tool's; empty, none.
        let tools: Set<String>?
        let body: String
    }

    /// A rule broken mid-reply: the reading stops here.
    struct Broken: Error {
        let rule: Rule
    }

    static let folders = [".formora/rules", ".omp/rules"]
    static let maxRules = 50

    /// The project's watched rules, Formora's folder first; a name met again is the same rule.
    static func load(root: URL) -> [Rule] {
        var rules: [Rule] = []
        for folder in folders {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { continue }
            for file in names.sorted() where file.hasSuffix(".md") || file.hasSuffix(".mdc") {
                let name = (file as NSString).deletingPathExtension
                guard !rules.contains(where: { $0.name == name }),
                      let text = try? String(contentsOf: url.appendingPathComponent(file), encoding: .utf8),
                      let rule = parse(text, name: name, path: folder + "/" + file) else { continue }
                rules.append(rule)
                if rules.count == maxRules { return rules }
            }
        }
        return rules
    }

    /// Front matter between `---` lines: `condition` (or omp's older `ttsr_trigger`) — one expression, a `[a, b]` list,
    /// or `- item` lines — and `scope`: `text`, `tool`, or tools by name (`tool:write`). The body is the rule. No
    /// condition that compiles: not a watched rule.
    static func parse(_ text: String, name: String, path: String) -> Rule? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var fields: [String: [String]] = [:]
        var key: String?
        for raw in lines[1..<close] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- "), let key {
                fields[key, default: []].append(unquote(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            key = field
            fields[field] = value.isEmpty ? [] : items(value)
        }
        let conditions = (fields["condition"] ?? fields["ttsr_trigger"] ?? [])
            .filter { !$0.isEmpty && (try? NSRegularExpression(pattern: $0)) != nil }
        guard !conditions.isEmpty else { return nil }
        let scope = (fields["scope"] ?? []).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let tools: Set<String>?
        if scope.isEmpty || scope.contains("tool") || scope.contains("toolcall") {
            tools = nil
        } else {
            tools = Set(scope.filter { $0 != "text" && $0 != "thinking" }.map { token in
                var tool = token.hasPrefix("tool:") ? String(token.dropFirst(5)) : token
                // omp's per-tool path globs, `tool:write(*.ts)`: the tool is what counts here.
                if let paren = tool.firstIndex(of: "(") { tool = String(tool[..<paren]) }
                return tool
            })
        }
        let body = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Rule(name: name, path: path, conditions: conditions, watchesText: scope.isEmpty || scope.contains("text"), tools: tools,
                    body: body.isEmpty ? (fields["description"]?.first ?? "不要写出匹配 \(conditions[0]) 的内容。") : body)
    }

    // MARK: Watching

    /// The first rule these words break.
    static func broken(text: String, rules: [Rule]) -> Rule? {
        rules.first { $0.watchesText && matches($0, text) }
    }

    /// The first rule a call's arguments break — the text they carry, JSON escapes undone.
    static func broken(call: ToolCall, rules: [Rule]) -> Rule? {
        let text = (ToolArguments.parse(call.arguments).map { strings($0) } ?? [call.arguments]).joined(separator: "\n")
        return rules.first { rule in (rule.tools?.contains(call.name.lowercased()) ?? true) && matches(rule, text) }
    }

    static func matches(_ rule: Rule, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return rule.conditions.contains { (try? NSRegularExpression(pattern: $0))?.firstMatch(in: text, range: range) != nil }
    }

    /// Rules already handed over in what the model still reads — after the latest compaction.
    static func fired(in messages: [Message]) -> Set<String> {
        Set(Compaction.effective(messages).messages.compactMap(\.rule))
    }

    /// What the model reads before it answers again (omp `ttsr-interrupt.md`).
    static func reminder(_ rule: Rule) -> String {
        "〔系统打断：你刚才的输出违反了用户为这个项目定的规则「\(rule.name)」（\(rule.path)），那段输出已经作废，里面的工具调用没有执行。"
            + "这不是注入，是 Formora 在执行项目规则。重新回答，必须遵守：\n\(rule.body)〕"
    }

    /// The thread's line, in the Agent's frame.
    static func marker(_ rule: Rule) -> String {
        "规则「\(rule.name)」：它刚才写的违反了这条规则，已打断并提醒它重来"
    }

    // MARK: Front matter

    /// One value, or a `[a, b]` list split at commas outside quotes and brackets — an expression may hold both.
    private static func items(_ value: String) -> [String] {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return [unquote(value)] }
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        for char in value.dropFirst().dropLast() {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\", quote != "'" {
                current.append(char)
                escaped = true
                continue
            }
            if let open = quote {
                current.append(char)
                if char == open { quote = nil }
                continue
            }
            switch char {
            case "\"", "'":
                quote = char
                current.append(char)
            case "(", "[", "{":
                depth += 1
                current.append(char)
            case ")", "]", "}":
                depth -= 1
                current.append(char)
            case "," where depth <= 0:
                parts.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        parts.append(current)
        return parts.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    /// YAML's quotes: single ones keep everything as written; double ones undo `\\`, `\"`, `\n` and `\t` and keep any
    /// other backslash, as a regular expression wants it.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var out = ""
        var escaped = false
        for char in value.dropFirst().dropLast() {
            if escaped {
                switch char {
                case "\\", "\"": out.append(char)
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out += "\\" + String(char)
                }
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                out.append(char)
            }
        }
        return out
    }

    private static func strings(_ value: Any) -> [String] {
        switch value {
        case let text as String: [text]
        case let object as [String: Any]: object.keys.sorted().flatMap { strings(object[$0] ?? "") }
        case let list as [Any]: list.flatMap { strings($0) }
        default: []
        }
    }
}
