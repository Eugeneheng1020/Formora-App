import Foundation

/// The script layer of computer use (7j, S1; the old app's phase 6): AppleScript or JavaScript through `osascript`, and
/// the user's own shortcuts. Behind the same 「允许操作电脑」 switch as `computer`; a script and a shortcut run are
/// commands (exec), listing shortcuts only reads. Out of the sandbox (B1′) they run as child processes: a deadline
/// really stops them, and macOS asks about each app a script drives on Formora's behalf.
enum ScriptTools {
    typealias Runner = @Sendable (_ command: String, _ input: Data, _ timeout: TimeInterval) async -> Shell.Result

    static let system: Runner = { command, input, timeout in
        await Shell.run(command, input: input, cwd: nil, timeout: timeout, environment: Shell.environment(projectPath: nil))
    }

    static let defaultTimeout: TimeInterval = 60
    static let timeoutLimit: TimeInterval = 300
    static let outputLimit = 20_000

    static let osascript = ToolSpec(
        name: "osascript",
        description: "Run an AppleScript or JavaScript for Automation (JXA) script on the user's Mac, to drive apps that support scripting — Finder, Safari, Notes, Calendar, Reminders, Mail, Music, System Events and many more — more reliably than clicking. The script's last value comes back. macOS asks the user once for each app a script controls; a refusal comes back as error -1743. `timeout` in seconds, default 60, at most 300.",
        parameters: #"{"type":"object","properties":{"script":{"type":"string","description":"The whole script"},"language":{"type":"string","enum":["applescript","javascript"],"description":"Default applescript"},"timeout":{"type":"number"}},"required":["script"]}"#,
        tier: .exec)

    static let shortcutList = ToolSpec(
        name: "shortcut_list",
        description: "List the user's own shortcuts (the Shortcuts app) by name; `folder` limits it to one of their folders.",
        parameters: #"{"type":"object","properties":{"folder":{"type":"string"}}}"#,
        tier: .read)

    static let shortcutRun = ToolSpec(
        name: "shortcut_run",
        description: "Run one of the user's shortcuts by its exact name (see shortcut_list). `input` is handed to it as text; what it outputs as text comes back.",
        parameters: #"{"type":"object","properties":{"name":{"type":"string"},"input":{"type":"string"}},"required":["name"]}"#,
        tier: .exec)

    static let all = [osascript, shortcutList, shortcutRun]
    static let names = Set(all.map(\.name))

    static func run(_ call: ToolCall, runner: Runner,
                    scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("FormoraShortcuts", isDirectory: true)) async -> ToolResult {
        let args = ToolArguments.parse(call.arguments) ?? [:]
        switch call.name {
        case osascript.name:
            guard let script = (args["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty else {
                return .failed("缺少 script")
            }
            let language = (args["language"] as? String)?.lowercased() == "javascript" ? "JavaScript" : "AppleScript"
            let timeout = min(timeoutLimit, max(1, (args["timeout"] as? NSNumber)?.doubleValue ?? defaultTimeout))
            let result = await runner("/usr/bin/osascript -l \(language) -", Data(script.utf8), timeout)
            if let failure = result.failure { return .failed(failure) }
            if result.timedOut { return .failed("脚本超过 \(Int(timeout)) 秒没跑完，已经停下") }
            guard result.exit == 0 else { return .failed(problem(result.stderr)) }
            let output = clip(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            return .done(output.isEmpty ? "脚本跑完了，没有返回值。" : output)

        case shortcutList.name:
            var command = "/usr/bin/shortcuts list"
            if let folder = args["folder"] as? String, !folder.isEmpty { command += " --folder-name " + quote(folder) }
            let result = await runner(command, Data(), 30)
            if let failure = result.failure { return .failed(failure) }
            guard result.exit == 0 else { return .failed("读不到快捷指令：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
            let found = result.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !found.isEmpty else { return .done("没有快捷指令。") }
            var text = "共 \(found.count) 个快捷指令：\n" + found.prefix(200).joined(separator: "\n")
            if found.count > 200 { text += "\n…（只列了前 200 个）" }
            return .done(text)

        case shortcutRun.name:
            guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return .failed("缺少 name") }
            let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            var command = "/usr/bin/shortcuts run " + quote(name)
            if let input = args["input"] as? String, !input.isEmpty {
                let url = folder.appendingPathComponent("input.txt")
                try? Data(input.utf8).write(to: url)
                command += " --input-path " + quote(url.path)
            }
            let output = folder.appendingPathComponent("output.txt")
            command += " --output-path " + quote(output.path) + " --output-type public.plain-text"
            let result = await runner(command, Data(), 120)
            if let failure = result.failure { return .failed(failure) }
            if result.timedOut { return .failed("快捷指令「\(name)」两分钟没跑完，已经停下") }
            guard result.exit == 0 else {
                let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed("快捷指令「\(name)」没跑成：\(error.isEmpty ? "没有说原因" : error)。名字要和 shortcut_list 里的一字不差")
            }
            let written = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let printed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = written.isEmpty ? printed : written
            return .done(text.isEmpty ? "快捷指令「\(name)」跑完了，没有输出文字。" : clip(text))

        default:
            return .failed("没有叫 \(call.name) 的工具")
        }
    }

    /// osascript's error in the product's words, where it is one of the usual ones.
    static func problem(_ stderr: String) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-1743") {
            return "macOS 没有允许 Formora 控制这个应用：在「系统设置 → 隐私与安全性 → 自动化」里，把 Formora 下面这个应用的开关打开。原文：\(text)"
        }
        if text.contains("-600") { return "那个应用没有在运行，先打开它（脚本里 activate 或 launch）。原文：\(text)" }
        if text.contains("-1712") { return "那个应用太久没有回应。原文：\(text)" }
        return text.isEmpty ? "脚本出错了，没有说原因" : "脚本出错了：\(text)"
    }

    /// A word for a bash command line: single-quoted, any single quote in it closed and escaped.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func clip(_ text: String) -> String {
        text.count > outputLimit ? String(text.prefix(outputLimit)) + "\n…（后面太长，省略了）" : text
    }
}
