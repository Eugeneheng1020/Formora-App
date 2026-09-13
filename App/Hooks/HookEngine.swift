import Foundation

/// What a hook is told (H1): Claude Code's stdin JSON — `session_id`, `hook_event_name`, `cwd`, `tool_name`,
/// `tool_input`, `tool_response`, `prompt`, `last_assistant_message`, `stop_hook_active` — plus Formora's own:
/// the Agent, the project, the task, and `message`, one line a person can read (what a chat robot posts).
struct HookInput: Sendable {
    var event: HookEvent
    var conversationID: UUID
    var title = ""
    var projectPath: String?
    var projectName: String?
    var agentID: UUID?
    var agentName: String?
    var agentRole: String?
    var permissionMode: String?
    var toolName: String?
    /// The call's arguments, JSON text.
    var toolInput: String?
    var toolUseID: String?
    var toolResponse: String?
    var prompt: String?
    var lastAssistantMessage: String?
    var stopHookActive = false
    var message = ""

    var payload: [String: Any] {
        var json: [String: Any] = ["session_id": conversationID.uuidString, "hook_event_name": event.rawValue, "message": message]
        if let projectPath { json["cwd"] = projectPath }
        if !title.isEmpty { json["task_title"] = title }
        if let projectName { json["project_name"] = projectName }
        if let agentID { json["agent_id"] = agentID.uuidString }
        if let agentName { json["agent_name"] = agentName }
        if let agentRole { json["agent_role"] = agentRole }
        if let permissionMode { json["permission_mode"] = permissionMode }
        if let toolName { json["tool_name"] = toolName }
        if let toolInput { json["tool_input"] = (try? JSONSerialization.jsonObject(with: Data(toolInput.utf8))) ?? toolInput }
        if let toolUseID { json["tool_use_id"] = toolUseID }
        if let toolResponse { json["tool_response"] = toolResponse }
        if let prompt { json["prompt"] = prompt }
        if let lastAssistantMessage { json["last_assistant_message"] = lastAssistantMessage }
        if event == .stop || event == .subagentStop { json["stop_hook_active"] = stopHookActive }
        if event == .sessionStart { json["source"] = "startup" }
        return json
    }

    var json: Data {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
}

/// What the hooks of one moment decided, together (H6).
struct HookOutcome: Equatable, Sendable {
    enum Permission: String, Sendable {
        case allow, deny, ask
    }

    /// A hook said no, and why: exit code 2, or `"decision": "block"`.
    var blocked: String?
    /// PreToolUse's `permissionDecision`.
    var permission: Permission?
    var permissionReason: String?
    /// For the model: `additionalContext`, or plain output of SessionStart / UserPromptSubmit.
    var context: [String] = []
    /// For the user: `systemMessage`, and hooks that failed or ran out of time.
    var notes: [String] = []
    /// `"continue": false`: the run ends, and why.
    var stopRun: String?

    /// Several hooks ran at once: a refusal wins, then deny over ask over allow; the rest adds up.
    mutating func merge(_ other: HookOutcome) {
        blocked = blocked ?? other.blocked
        let rank: [Permission: Int] = [.allow: 0, .ask: 1, .deny: 2]
        if let theirs = other.permission, (permission.flatMap { rank[$0] } ?? -1) < (rank[theirs] ?? 0) {
            permission = theirs
            permissionReason = other.permissionReason
        }
        context += other.context
        notes += other.notes
        stopRun = stopRun ?? other.stopRun
    }
}

/// Runs one hook (H5): a command with bash in the project folder, the event as JSON on its standard input (the same
/// runner as the bash tool, 7c); or a POST to a URL. Off the main actor; never throws — whatever goes wrong becomes
/// a note.
enum HookEngine {
    typealias Execution = Shell.Result

    static let outputLimit = 64_000

    static func run(_ handler: HookHandler, input: HookInput, cwd: URL?) async -> HookOutcome {
        let timeout = min(600, max(1, handler.timeout ?? input.event.defaultTimeout))
        switch handler.kind {
        case .command(let command):
            let execution = await runCommand(command, input: input.json, cwd: cwd, timeout: TimeInterval(timeout),
                                             environment: environment(projectPath: cwd?.path, event: input.event))
            return interpret(execution, event: input.event, name: handler.name, timeout: timeout, plainIsContext: true)
        case let .http(url, format):
            let execution = await post(url, body: format.body(input), headers: handler.headers, timeout: TimeInterval(timeout))
            return interpret(execution, event: input.event, name: handler.name, timeout: timeout, plainIsContext: false)
        case .unsupported:
            return HookOutcome()
        }
    }

    /// The shell's environment, plus the moment.
    static func environment(projectPath: String?, event: HookEvent) -> [String: String] {
        var environment = Shell.environment(projectPath: projectPath)
        environment["FORMORA_HOOK_EVENT"] = event.rawValue
        return environment
    }

    static func runCommand(_ command: String, input: Data, cwd: URL?, timeout: TimeInterval, environment: [String: String]) async -> Execution {
        var result = await Shell.run(command, input: input, cwd: cwd, timeout: timeout, environment: environment)
        result.stdout = String(result.stdout.prefix(outputLimit))
        result.stderr = String(result.stderr.prefix(outputLimit))
        return result
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data.prefix(outputLimit), as: UTF8.self)
    }

    // MARK: URL

    /// POSTs the body; a 2xx is a success whose body is read like a command's output. Chat robots answer 200 even
    /// when they refuse, with a non-zero `code` / `errcode` — that is a failure too.
    static func post(_ url: String, body: Data, headers: [String: String], timeout: TimeInterval) async -> Execution {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = target.scheme?.lowercased(),
              scheme == "https" || scheme == "http", target.host != nil else {
            return Execution(failure: "「\(url)」不是能用的网址")
        }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = text(data)
            guard (200..<300).contains(status) else {
                return Execution(failure: "\(target.host ?? url) 返回了 \(status)\(text.isEmpty ? "" : "：\(text.prefix(200))")")
            }
            if let reason = robotRefusal(data) { return Execution(failure: "机器人没有收下：\(reason)") }
            return Execution(exit: 0, stdout: text)
        } catch let error as URLError where error.code == .timedOut {
            return Execution(timedOut: true)
        } catch {
            return Execution(failure: "发不出去：\(error.localizedDescription)")
        }
    }

    /// Feishu, WeCom and DingTalk answer 200 with a non-zero `code` / `errcode` when they refuse a message.
    static func robotRefusal(_ data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = (json["code"] ?? json["errcode"] ?? json["StatusCode"]) as? Int, code != 0 else { return nil }
        return (json["msg"] ?? json["errmsg"] ?? json["StatusMessage"]) as? String ?? "错误码 \(code)"
    }

    // MARK: Reading what came back (H6)

    static func interpret(_ execution: Execution, event: HookEvent, name: String, timeout: Int, plainIsContext: Bool) -> HookOutcome {
        var outcome = HookOutcome()
        if execution.timedOut {
            outcome.notes.append("Hook「\(name)」超过 \(timeout) 秒没有结束，这次没有起作用")
            return outcome
        }
        if let failure = execution.failure {
            outcome.notes.append("Hook「\(name)」没有运行成功：\(failure)")
            return outcome
        }
        let stdout = execution.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = execution.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if execution.exit == 2 {
            let reason = stderr.isEmpty ? "Hook「\(name)」拦下了" : stderr
            if event.canBlock { outcome.blocked = reason } else { outcome.notes.append("Hook「\(name)」：\(reason)") }
            return outcome
        }
        if stdout.hasPrefix("{"), stdout.hasSuffix("}"),
           let json = (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any] {
            apply(json, to: &outcome, event: event, name: name)
            return outcome
        }
        if execution.exit == 0 {
            if plainIsContext, !stdout.isEmpty, event == .sessionStart || event == .subagentStart || event == .userPromptSubmit { outcome.context.append(stdout) }
            return outcome
        }
        let code = execution.exit.map(String.init) ?? "?"
        outcome.notes.append("Hook「\(name)」出错了（退出码 \(code)）\(stderr.isEmpty ? "" : "：\(stderr.prefix(200))")")
        return outcome
    }

    private static func apply(_ json: [String: Any], to outcome: inout HookOutcome, event: HookEvent, name: String) {
        let specific = json["hookSpecificOutput"] as? [String: Any] ?? [:]
        let decision = (json["decision"] as? String)?.lowercased()
        if decision == "block", event.canBlock {
            outcome.blocked = (json["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Hook「\(name)」拦下了"
        }
        if event == .preToolUse {
            // Claude Code's current field, and its older top-level `approve`.
            if let raw = (specific["permissionDecision"] as? String)?.lowercased(), let permission = HookOutcome.Permission(rawValue: raw) {
                outcome.permission = permission
                outcome.permissionReason = specific["permissionDecisionReason"] as? String
            } else if decision == "approve" {
                outcome.permission = .allow
            }
        }
        if let context = specific["additionalContext"] as? String, !context.isEmpty { outcome.context.append(context) }
        if let message = json["systemMessage"] as? String, !message.isEmpty { outcome.notes.append(message) }
        if json["continue"] as? Bool == false {
            outcome.stopRun = (json["stopReason"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Hook「\(name)」让它停下"
        }
    }
}
