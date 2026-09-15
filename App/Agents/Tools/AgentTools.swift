import Foundation

/// How far a tool reaches (omp `ToolTier`): reading, writing files, running things.
enum ToolTier: Int, Comparable, Sendable {
    case read, write, exec

    static func < (a: ToolTier, b: ToolTier) -> Bool { a.rawValue < b.rawValue }
}

/// An Agent's 权限模式 (omp `ApprovalMode`, 7b L5): the highest tier that runs without asking. A call above it
/// waits on its card for 允许 / 拒绝.
enum ApprovalMode: String, Codable, CaseIterable, Sendable {
    case alwaysAsk, write, yolo

    var label: String {
        switch self {
        case .alwaysAsk: "每次询问"
        case .write: "允许写入"
        case .yolo: "全部放行"
        }
    }

    var note: String {
        switch self {
        case .alwaysAsk: "查看文件和搜索直接做；写文件、读网页、执行命令之前都先问你。"
        case .write: "查看和写文件、搜索直接做；读网页、执行命令之前先问你。"
        case .yolo: "所有操作直接做，不再询问。只在你信得过这个 Agent 和项目时用。"
        }
    }

    var allows: ToolTier {
        switch self {
        case .alwaysAsk: .read
        case .write: .write
        case .yolo: .exec
        }
    }

    func needsApproval(_ tier: ToolTier) -> Bool { tier > allows }
}

/// A tool as the model is offered it.
struct ToolSpec: Sendable {
    let name: String
    let description: String
    /// JSON Schema of the arguments, as JSON text (kept `Sendable`; parsed when a request is built).
    let parameters: String
    let tier: ToolTier

    var schema: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(parameters.utf8))) as? [String: Any] ?? ["type": "object", "properties": [:]]
    }
}

/// The tools an Agent works with: the file tools (7b), a shell and the web (7c). Descriptions are written for the
/// model, never shown.
enum AgentTools {
    static let read = ToolSpec(
        name: "read",
        description: "Read a text file in the project folder. Returns numbered lines. For a long file, pass offset (1-based line) and limit to read a part. Reading a folder lists what is in it. Reading an image (png, jpg, gif, webp, heic…) hands you the picture itself when your model can see images. Other binary files (.docx, .xlsx, .pptx, .pdf) can't be read as text.",
        parameters: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the project folder"},"offset":{"type":"integer","description":"First line to read, 1-based"},"limit":{"type":"integer","description":"How many lines to read (at most 2000)"}},"required":["path"]}"#,
        tier: .read)

    static let glob = ToolSpec(
        name: "glob",
        description: "Find files in the project folder by name pattern. `*` matches within one folder, `**` across folders, `{a,b}` either: `**/*.md`, `PRD/*.md`. A pattern without `/` matches file names at any depth. Returns project-relative paths, at most 200.",
        parameters: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern"},"path":{"type":"string","description":"Folder to search in, relative to the project folder; the whole project if omitted"}},"required":["pattern"]}"#,
        tier: .read)

    static let grep = ToolSpec(
        name: "grep",
        description: "Search file contents in the project folder with a regular expression. Returns `path:line: text` per matching line, at most 200. Narrow it with path (a folder or a file) and glob (a file name pattern such as `*.md`).",
        parameters: #"{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression"},"path":{"type":"string","description":"Folder or file to search, relative to the project folder"},"glob":{"type":"string","description":"Only files matching this name pattern"},"ignore_case":{"type":"boolean","description":"Match regardless of case"}},"required":["pattern"]}"#,
        tier: .read)

    static let write = ToolSpec(
        name: "write",
        description: "Create a file in the project folder, or replace its whole content. Missing folders are created. Read an existing file before replacing it; to change part of a file, use edit.",
        parameters: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the project folder"},"content":{"type":"string","description":"The complete file content"}},"required":["path","content"]}"#,
        tier: .write)

    static let edit = ToolSpec(
        name: "edit",
        description: "Replace exact text in a file of the project folder. old_text must match the file exactly, spaces and line breaks included, and appear once unless replace_all is true. Read the file first.",
        parameters: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the project folder"},"old_text":{"type":"string","description":"The exact text to replace"},"new_text":{"type":"string","description":"What to put in its place"},"replace_all":{"type":"boolean","description":"Replace every occurrence"}},"required":["path","old_text","new_text"]}"#,
        tier: .write)

    /// Only the App Store build is sandboxed, where macOS's stand-ins refuse to run; the Developer ID build has no
    /// sandbox (7j, B1′), and telling its model otherwise would steer it off the system tools for nothing.
    #if FORMORA_DEVELOPER_ID
    static let shellNote = ""
    #else
    static let shellNote = " The app is sandboxed: macOS's stand-ins such as /usr/bin/python3 or /usr/bin/git may refuse to run — use the Homebrew ones in /opt/homebrew/bin."
    #endif

    static let bash = ToolSpec(
        name: "bash",
        description: "Run a shell command with bash in the project folder; returns its output (stdout, then stderr) and a non-zero exit code. For builds, tests, scripts, git, package managers. Stopped after 300 seconds unless timeout says otherwise (at most 600). Long output keeps its beginning and its end.\(shellNote) For files, prefer read, glob, grep, write and edit. For what keeps running — a dev server, a watcher, a long build — pass background: true: it returns at once with a job id (j1…) and its first output, and timeout doesn't apply; read on with bash_output, stop it with bash_stop, and you are told when it ends. At most 8 at a time.",
        parameters: #"{"type":"object","properties":{"command":{"type":"string","description":"The command line to run"},"timeout":{"type":"integer","description":"Seconds before it is stopped (default 300, at most 600)"},"background":{"type":"boolean","description":"Keep it running in the background: servers, watchers, long builds"}},"required":["command"]}"#,
        tier: .exec)

    static let webSearch = ToolSpec(
        name: "web_search",
        description: "Search the web. Returns titles, addresses and snippets — or, with some providers, a short answer with its sources. Read a page in full with fetch.",
        parameters: #"{"type":"object","properties":{"query":{"type":"string","description":"What to search for"},"max_results":{"type":"integer","description":"How many results (default 8, at most 15)"}},"required":["query"]}"#,
        tier: .read)

    static let fetch = ToolSpec(
        name: "fetch",
        description: "Read a public web page or API with an HTTP GET, without any login or cookies. HTML comes back as plain text with its title; JSON and plain text as they are. At most 20,000 characters per call; pass offset to read on. Pages behind a login can't be read.",
        parameters: #"{"type":"object","properties":{"url":{"type":"string","description":"An http:// or https:// address"},"offset":{"type":"integer","description":"Character to start from, for a long page"}},"required":["url"]}"#,
        // Asks like a command (review 2026-09-12, D70): with files read freely, a page's hidden instructions could
        // otherwise carry the project out in an address, unseen.
        tier: .exec)

    static let openURL = ToolSpec(
        name: "open_url",
        description: "Open a web address in the user's own browser, for the user to see: a document, a sign-in page, a preview. You don't get the page's content — use fetch for that.",
        parameters: #"{"type":"object","properties":{"url":{"type":"string","description":"An http:// or https:// address"}},"required":["url"]}"#,
        tier: .exec)

    static let all: [ToolSpec] = [read, glob, grep, write, edit, bash, webSearch, fetch, openURL]

    static func spec(_ name: String) -> ToolSpec? { all.first { $0.name == name } }

    /// Runs one call, off the main actor. Never throws: a refusal or an error is a result the model reads and can act
    /// on (omp: tool failures go back to the model). The file tools and bash need the project folder; the web ones
    /// don't. `search` is the Agent's own provider when it searches natively (C5).
    static func run(_ call: ToolCall, root: URL?, search: ChatTarget? = nil, readRoots: [URL] = [], writeRoots: [URL] = [],
                    history: URL? = nil) async -> ToolResult {
        guard spec(call.name) != nil else {
            return .failed("没有叫 \(call.name) 的工具。能用的工具：\(all.map(\.name).joined(separator: "、"))")
        }
        switch call.name {
        case "bash": return await BashTool.run(arguments: call.arguments, root: root)
        case "web_search": return await WebTools.search(arguments: call.arguments, native: search)
        case "fetch": return await WebTools.fetch(arguments: call.arguments)
        case "open_url": return await WebTools.open(arguments: call.arguments)
        default:
            guard let root else {
                return .failed("项目文件夹现在打不开（可能被移动或删除了），这一步没有执行。请用户在「文件」里重新打开项目。")
            }
            let name = call.name, arguments = call.arguments
            return await Task.detached {
                FileTools.run(name, arguments: arguments, root: root, readRoots: readRoots, writeRoots: writeRoots, history: history)
            }.value
        }
    }

    /// Why this call asks the user whatever the 权限模式 and whatever a hook allowed (C3): a dangerous command.
    /// Why a step asks whatever a hook or a grant said: a new MCP service in every mode; the seven kinds of dangerous
    /// command unless the mode is 全部放行 (user 2026-09-15: there they run, on trust).
    static func forcedApproval(_ call: ToolCall, mode: ApprovalMode) -> String? {
        // Connecting a new MCP service always asks (7h, B9).
        if call.name == "mcp_add" {
            // One that starts on this Mac runs as the user: the card shows its command (9d, S6).
            return MCPConnect.commandLine(call.arguments) == nil ? "要接入一个新的 MCP 服务" : "要在这台 Mac 上启动一个 MCP 服务，它会以你的身份运行下面这条命令"
        }
        guard mode != .yolo, call.name == "bash", let command = ToolArguments.parse(call.arguments)?["command"] as? String else { return nil }
        return CommandRisk.reason(command)
    }

    /// As 每次询问 has it: what the QA seeds and the old call sites mean.
    static func forcedApproval(_ call: ToolCall) -> String? { forcedApproval(call, mode: .alwaysAsk) }
}

/// A call's arguments: the JSON object the model wrote.
enum ToolArguments {
    static func parse(_ json: String) -> [String: Any]? {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? JSONSerialization.jsonObject(with: Data((text.isEmpty ? "{}" : text).utf8))) as? [String: Any]
    }

    static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? Double { return Int(value) }
        return (args[key] as? String).flatMap { Int($0) }
    }
}

extension ToolCall {
    /// The card's line and the list preview: what the call does, in the product's words.
    var summary: String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let path = (args["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch name {
        case "read": return "读取 \(path ?? "文件")"
        case "glob": return "查找 \(args["pattern"] as? String ?? "文件")"
        case "grep": return "搜索「\(args["pattern"] as? String ?? "")」"
        case "write": return "写入 \(path ?? "文件")"
        case "edit": return "修改 \(path ?? "文件")"
        case "bash":
            let line = (args["command"] as? String)?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return ((args["background"] as? Bool) == true ? "后台运行 " : "运行 ") + Self.short(line)
        case "bash_output": return "查看后台命令 \(args["id"] as? String ?? "") 的输出"
        case "bash_stop": return "停止后台命令 \(args["id"] as? String ?? "")"
        case "web_search": return "搜索网络「\(args["query"] as? String ?? "")」"
        case "fetch":
            let url = (args["url"] as? String).flatMap(URL.init(string:))
            return "读取网页 \(Self.short(url.map { ($0.host ?? "") + $0.path } ?? (args["url"] as? String ?? "")))"
        case "open_url": return "在浏览器打开 \(Self.short(args["url"] as? String ?? ""))"
        case "plan": return "更新计划"
        case TextToolProtocol.malformedName: return "格式不对的工具调用"
        case "skill": return "读取 Skill「\(args["name"] as? String ?? "")」"
        case "skill_create": return "新建 Skill「\(args["name"] as? String ?? "")」"
        case "remember":
            if let rewrite = args["rewrite"] as? String, !rewrite.isEmpty { return "整理记忆" }
            return "记下：\(Self.short(args["note"] as? String ?? ""))"
        case "ask":
            let first = ((args["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? ""
            return "问你：\(Self.short(first))"
        case TeamTools.handoff.name: return "交给 \(args["to"] as? String ?? "")"
        case TeamTools.delegateName:
            let task = (args["task"] as? String)?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return "委派给 \(Delegation.parse(arguments)?.to ?? "分身")：\(Self.short(task))"
        case TeamTools.goalDone.name: return "提交目标，等复核"
        case "formora_help": return "读说明「\(args["topic"] as? String ?? "")」"
        case "formora_state":
            let labels = ["agents": "Agent", "tasks": "任务进度", "project": "项目与目录", "models": "模型", "skills": "Skills", "mcp": "MCP", "notifications": "通知"]
            return "查看现状：\(labels[args["section"] as? String ?? ""] ?? "全部")"
        case "mcp_catalog": return "查看 MCP 推荐目录"
        case "mcp_add":
            let target = [args["catalog_id"], args["name"], args["url"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? "服务"
            return "接入 MCP \(Self.short(target))"
        case "folder_create": return "新建文件夹 \(path ?? "")"
        case "notification_set":
            let labels = ["desktop": "桌面通知", "sound": "提示音", "badge": "程序坞未读数"]
            return ((args["on"] as? Bool ?? true) ? "打开" : "关掉") + (labels[args["setting"] as? String ?? ""] ?? "通知")
        case ComputerTool.name: return ComputerTool.summary(arguments)
        case ScriptTools.osascript.name:
            let line = (args["script"] as? String)?.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            return "运行脚本 \(Self.short(line))"
        case ScriptTools.shortcutList.name: return "查看你的快捷指令"
        case ScriptTools.shortcutRun.name: return "运行快捷指令「\(args["name"] as? String ?? "")」"
        default:
            if let parts = MCPTools.parts(of: name) { return "调用 MCP \(parts.server) · \(parts.tool)" }
            return "调用 \(name)"
        }
    }

    private static func short(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
