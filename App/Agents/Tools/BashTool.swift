import Foundation

/// bash (7c, C1–C2; old 4e): one command in the project folder, 300 seconds unless the model asks for another (at
/// most 600); the output keeps its head and its tail. The exec tier; CommandRisk's seven kinds always ask.
enum BashTool {
    static let defaultTimeout = 300
    static let maxTimeout = 600
    static let outputLimit = 30_000

    static func run(arguments json: String, root: URL?) async -> ToolResult {
        guard let args = ToolArguments.parse(json) else { return .failed("参数不是合法的 JSON 对象：\(json.prefix(200))") }
        guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return .failed("缺少参数 command")
        }
        guard let root else {
            return .failed("项目文件夹现在打不开，不能运行命令。请用户在 Formora 里重新打开项目。")
        }
        let timeout = min(max(ToolArguments.int(args, "timeout") ?? defaultTimeout, 1), maxTimeout)
        let result = await Shell.run(command, cwd: root, timeout: TimeInterval(timeout), environment: Shell.environment(projectPath: root.path))
        return outcome(result, timeout: timeout)
    }

    /// What the model reads: the output, then what went to stderr; the exit code when it isn't 0.
    static func outcome(_ result: Shell.Result, timeout: Int) -> ToolResult {
        if let failure = result.failure {
            return ToolResult(status: failure == Shell.stopped ? .stopped : .failed, output: failure)
        }
        var text = result.stdout.trimmingCharacters(in: .newlines)
        let errors = result.stderr.trimmingCharacters(in: .newlines)
        if !errors.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + errors }
        text = trimmed(text, limit: outputLimit)
        if result.timedOut {
            return .failed("超过 \(timeout) 秒还没结束，已经停下了。" + (text.isEmpty ? "" : "停下前的输出：\n\(text)"))
        }
        let code = result.exit ?? -1
        if code == 0 { return .done(text.isEmpty ? "（运行成功，没有输出）" : text) }
        return .failed("退出码 \(code)\n" + (text.isEmpty ? "（没有输出）" : text))
    }

    /// A third of the room for the beginning, the rest for the end — where errors and summaries usually are.
    static func trimmed(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit / 3)
        let tail = text.suffix(limit - limit / 3)
        return "\(head)\n\n…（中间省略了 \(text.count - head.count - tail.count) 字）…\n\n\(tail)"
    }
}
