import Foundation

/// What the user opens, edits and backs up — the Skill library, the global hooks, the memories, the MCP configuration
/// — lives in `~/.formora/`, the way Claude Code keeps `~/.claude/` (user 2026-09-14). Only for the default profile of
/// a build outside the sandbox: a sandboxed build can't reach the home folder, a named profile (QA) never touches the
/// user's own, and tests neither — those keep everything in Application Support. What an earlier version kept there
/// comes over once, and nothing already in the new place is overwritten.
enum UserResources {
    static let folderName = ".formora"
    static let skillsFolder = "skills"
    /// The subagents' definitions (user 2026-09-15), the way Claude Code keeps `~/.claude/agents/`.
    static let agentsFolder = "agents"
    static let memoryFolder = "memory"
    static let hooksFile = "hooks.json"
    static let mcpFile = "mcp.json"
    /// The old names in Application Support (`SkillLibrary`, `MemoryStore.folderName`, `HookStore.fileName`, `MCPStore.fileName`).
    static let oldSkillsFolder = "Skills"
    static let oldMemoryFolder = "Memory"
    static let oldMCPFile = "MCPServers.json"

    /// Where they live this launch; `nil` keeps them in Application Support.
    static func directory(for profile: AppProfile, environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard profile.isDefault, environment["APP_SANDBOX_CONTAINER_ID"] == nil,
              environment["XCTestConfigurationFilePath"] == nil, environment["XCTestBundlePath"] == nil else { return nil }
        return home.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The four places, in `directory` when there is one, else where they always were.
    struct Places {
        let skills: URL?
        let memory: URL?
        /// The folder holding `hooks.json`.
        let hooks: URL?
        let mcp: URL?
        /// `nil` (a sandboxed build, a named profile): the built-in subagents live in memory.
        var agents: URL? = nil
    }

    static func places(support: URL?, directory: URL?) -> Places {
        if let directory {
            return Places(skills: directory.appendingPathComponent(skillsFolder, isDirectory: true),
                          memory: directory.appendingPathComponent(memoryFolder, isDirectory: true),
                          hooks: directory, mcp: directory.appendingPathComponent(mcpFile),
                          agents: directory.appendingPathComponent(agentsFolder, isDirectory: true))
        }
        return Places(skills: support?.appendingPathComponent(oldSkillsFolder, isDirectory: true),
                      memory: support?.appendingPathComponent(oldMemoryFolder, isDirectory: true),
                      hooks: support, mcp: support?.appendingPathComponent(oldMCPFile))
    }

    /// What came over: the new names. Each moves only when the old one is there and the new one isn't.
    @discardableResult
    static func migrate(from support: URL, to directory: URL, fileManager: FileManager = .default) -> [String] {
        let pairs = [(oldSkillsFolder, skillsFolder), (oldMemoryFolder, memoryFolder), (hooksFile, hooksFile), (oldMCPFile, mcpFile)]
        var moved: [String] = []
        for (old, new) in pairs {
            let source = support.appendingPathComponent(old)
            let target = directory.appendingPathComponent(new)
            guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? fileManager.moveItem(at: source, to: target)) != nil { moved.append(new) }
        }
        return moved
    }
}
