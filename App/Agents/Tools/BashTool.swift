import Foundation

/// bash (7c, C1–C2; old 4e): one command in the project folder, 300 seconds unless the model asks for another (at
/// most 600); the output keeps its head and its tail. The exec tier; CommandRisk's seven kinds always ask.
enum BashTool {
    static let defaultTimeout = 300
    static let maxTimeout = 600
    static let outputLimit = 30_000

    /// `aside`: asked to, a command still running steps aside (user 2026-09-17) — what it printed comes back, and the
    /// caller takes the command over as a background job.
    static func run(arguments json: String, root: URL?, aside: Shell.Aside? = nil) async -> ToolResult {
        guard let args = ToolArguments.parse(json) else { return .failed("参数不是合法的 JSON 对象：\(json.prefix(200))") }
        guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return .failed("缺少参数 command")
        }
        guard let root else {
            return .failed("项目文件夹现在打不开，不能运行命令。请用户在 Formora 里重新打开项目。")
        }
        let timeout = min(max(ToolArguments.int(args, "timeout") ?? defaultTimeout, 1), maxTimeout)
        let result = await Shell.run(command, cwd: root, timeout: TimeInterval(timeout), environment: Shell.environment(projectPath: root.path),
                                     aside: aside)
        return outcome(result, timeout: timeout)
    }

    /// What the model reads of a command that stepped aside for the user's message.
    static func asideNote(job: String, printed: String) -> String {
        "用户发来了新消息，这条命令还没跑完，已经转到后台继续运行，编号 \(job)。"
            + (printed.isEmpty ? "到现在还没有输出。" : "到现在的输出：\n" + printed)
            + "\n先处理用户的新消息。之后用 bash_output 看它的输出，用 bash_stop 停止；它自己结束时你会收到通知。"
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
        // Still running, in the background now: only what it printed — the caller says the rest.
        if result.steppedAside { return .done(text) }
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
