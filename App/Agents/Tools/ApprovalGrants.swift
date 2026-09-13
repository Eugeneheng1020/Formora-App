import Foundation
import Observation

/// 10b: an approval that remembers (Codex `ReviewDecision::ApprovedForSession` / `ApprovedExecpolicyAmendment`, its
/// prefix rules; omp's per-tool policy). What can be remembered: a tool by its name, a command by its whole simple
/// command — later ones starting with the same words count.
struct ApprovalGrant: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case tool, command
    }

    var kind: Kind
    var value: String
    var createdAt = Date()

    var id: String { kind.rawValue + ":" + value }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind && lhs.value == rhs.value }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The user's choice on a card (10b).
enum ApprovalChoice: Equatable, Sendable {
    case once, conversation, project, deny
}

enum ApprovalGrants {
    /// Never offered: operating the Mac and running scripts ask every time (7j); `mcp_add` always asks (forced).
    static let neverRemembered: Set<String> = Set([ComputerTool.name, "mcp_add"]).union(ScriptTools.names)

    /// Too wide to remember (Codex `BANNED_PREFIX_SUGGESTIONS`): a shell or an interpreter with its code inline, bare
    /// `git`, a package manager's `run`, and wrappers that run whatever follows.
    static let interpreters: Set<String> = ["bash", "sh", "zsh", "fish", "dash", "ksh", "python", "python3", "node", "nodejs", "ruby",
                                            "perl", "php", "lua", "julia", "deno", "bun", "Rscript", "osascript", "cmd", "powershell", "pwsh"]
    static let inlineFlags: Set<String> = ["-c", "-lc", "-e", "-r", "eval"]
    static let wrappers: Set<String> = ["env", "sudo", "su", "doas", "xargs", "eval", "exec", "nohup", "time", "command", "watch"]
    static let bannedExactly: [[String]] = [["git"], ["npm", "run"], ["pnpm", "run"], ["yarn", "run"], ["bun", "run"], ["npx"]]

    /// What this call could be remembered as; `nil` when it can't be.
    static func offer(for call: ToolCall) -> ApprovalGrant? {
        guard !neverRemembered.contains(call.name) else { return nil }
        guard call.name == "bash" else { return ApprovalGrant(kind: .tool, value: call.name) }
        guard let command = ToolArguments.parse(call.arguments)?["command"] as? String, let words = rememberable(command) else { return nil }
        return ApprovalGrant(kind: .command, value: words.joined(separator: " "))
    }

    /// A single simple command worth remembering, as words; `nil` for a compound one, a redirection, or one too wide.
    static func rememberable(_ command: String) -> [String]? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, CommandRisk.simpleCommands(trimmed).count == 1,
              trimmed.range(of: #"[;&|<>`\n]|\$\("#, options: .regularExpression) == nil else { return nil }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        if wrappers.contains(first) { return nil }
        if interpreters.contains(first), words.count == 1 || inlineFlags.contains(words[1]) { return nil }
        if bannedExactly.contains(words) { return nil }
        return words
    }

    /// Whether a remembered grant lets this call through.
    static func covers(_ grant: ApprovalGrant, _ call: ToolCall) -> Bool {
        switch grant.kind {
        case .tool:
            return call.name == grant.value && !neverRemembered.contains(call.name)
        case .command:
            guard call.name == "bash", let command = ToolArguments.parse(call.arguments)?["command"] as? String,
                  let words = rememberable(command) else { return false }
            let prefix = grant.value.split(separator: " ").map(String.init)
            return words.count >= prefix.count && Array(words.prefix(prefix.count)) == prefix
        }
    }

    /// As the card and 管理项目 say it.
    static func label(_ grant: ApprovalGrant) -> String {
        switch grant.kind {
        case .command:
            return "「\(grant.value)」开头的命令"
        case .tool:
            switch grant.value {
            case "write": return "写文件"
            case "edit": return "改文件"
            case "fetch": return "读网页"
            case "open_url": return "打开网页"
            default:
                guard grant.value.hasPrefix(MCPTools.prefix) else { return "「\(grant.value)」" }
                let parts = grant.value.dropFirst(MCPTools.prefix.count).components(separatedBy: "__")
                return parts.count >= 2 ? "MCP「\(parts[0])」的 \(parts.dropFirst().joined(separator: "__"))" : "MCP「\(parts[0])」"
            }
        }
    }
}

/// What each project no longer asks about (10b): kept in a file, listed and removed in 管理项目 (spec §8.7 rule 1 —
/// what can be added can be removed, in one place). A rule is about the step, not the Agent: every Agent in the project.
@MainActor
@Observable
final class ApprovalRuleStore {
    static let fileName = "ApprovalRules.json"

    private(set) var rules: [UUID: [ApprovalGrant]] = [:]
    @ObservationIgnored private let fileURL: URL?

    /// `fileURL == nil` keeps them in memory (tests, previews).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: [ApprovalGrant]].self, from: data) {
            rules = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        }
    }

    func rules(for project: UUID) -> [ApprovalGrant] { rules[project] ?? [] }

    func covers(_ call: ToolCall, project: UUID) -> Bool {
        rules(for: project).contains { ApprovalGrants.covers($0, call) }
    }

    func add(_ grant: ApprovalGrant, project: UUID) {
        guard !rules(for: project).contains(grant) else { return }
        rules[project, default: []].append(grant)
        save()
    }

    func remove(_ grant: ApprovalGrant, project: UUID) {
        rules[project]?.removeAll { $0 == grant }
        if rules[project]?.isEmpty == true { rules[project] = nil }
        save()
    }

    /// The project left Formora: its rules go with it.
    func removeAll(project: UUID) {
        guard rules.removeValue(forKey: project) != nil else { return }
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let saved = Dictionary(uniqueKeysWithValues: rules.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
