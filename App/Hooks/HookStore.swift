import CryptoKit
import Foundation
import Observation

/// The hooks (7b′, H3–H4): global ones in `<profile>/hooks.json`, a project's in `<project>/.formora/hooks.json`,
/// both in Claude Code's shape. A project's hooks run only once the user has switched them on, and again only after
/// a change is looked at — the file's SHA-256 is remembered; a change saved through the form counts as consent.
@MainActor
@Observable
final class HookStore {
    enum Scope: Hashable {
        case global
        case project(URL)
    }

    struct ProjectHooks: Equatable {
        var file = HookFile()
        var exists = false
        var problem: String?
        var isTrusted = false
    }

    nonisolated static let fileName = "hooks.json"
    nonisolated static let trustFileName = "hook-trust.json"

    private(set) var global = HookFile()
    private(set) var globalProblem: String?
    /// Bumped on every change, so a view showing a project's file reads it again.
    private(set) var revision = 0

    @ObservationIgnored private let folder: URL?
    /// Project folder → the SHA-256 of the hooks file the user switched on.
    @ObservationIgnored private var trusted: [String: String] = [:]

    /// `folder == nil` keeps everything in memory (tests, previews).
    init(folder: URL?) {
        self.folder = folder
        if let url = folder?.appendingPathComponent(Self.trustFileName), let data = try? Data(contentsOf: url) {
            trusted = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        reload()
    }

    var globalURL: URL? { folder?.appendingPathComponent(Self.fileName) }

    nonisolated static func projectURL(_ root: URL) -> URL {
        root.appendingPathComponent(".formora", isDirectory: true).appendingPathComponent(fileName)
    }

    /// Reads the global file again (it may have been edited in another app).
    func reload() {
        if let url = globalURL, let data = try? Data(contentsOf: url) {
            do {
                global = try HookFile.parse(data)
                globalProblem = nil
            } catch {
                global = HookFile()
                globalProblem = (error as? HookFile.Problem)?.message ?? error.localizedDescription
            }
        } else if globalURL != nil {
            global = HookFile()
            globalProblem = nil
        }
        revision += 1
    }

    func project(_ root: URL) -> ProjectHooks {
        _ = revision
        guard let data = try? Data(contentsOf: Self.projectURL(root)) else { return ProjectHooks() }
        var hooks = ProjectHooks(exists: true)
        do {
            hooks.file = try HookFile.parse(data)
        } catch {
            hooks.problem = (error as? HookFile.Problem)?.message ?? error.localizedDescription
        }
        hooks.isTrusted = trusted[key(root)] == Self.digest(data)
        return hooks
    }

    func file(_ scope: Scope) -> HookFile {
        switch scope {
        case .global: global
        case .project(let root): project(root).file
        }
    }

    /// 启用: the project's hooks, as the file is now, may run.
    func trust(_ root: URL) {
        guard let data = try? Data(contentsOf: Self.projectURL(root)) else { return }
        trusted[key(root)] = Self.digest(data)
        saveTrust()
        revision += 1
    }

    func save(_ file: HookFile, to scope: Scope) throws {
        let data = file.encoded()
        switch scope {
        case .global:
            guard let url = globalURL else {
                global = file
                revision += 1
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            reload()
        case .project(let root):
            let url = Self.projectURL(root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            // Saved from this app's own form: the user's change, so it runs as it is now (H4).
            trusted[key(root)] = Self.digest(data)
            saveTrust()
            revision += 1
        }
    }

    /// Global hooks, and the project's once switched on, that fit this moment and tool.
    func handlers(_ event: HookEvent, tool: String?, projectRoot: URL?) -> [HookHandler] {
        var files = [global]
        if let projectRoot {
            let project = project(projectRoot)
            if project.isTrusted, project.problem == nil { files.append(project.file) }
        }
        let subject = event.usesToolMatcher ? (tool ?? "") : "startup"
        let matched = files.flatMap { file in
            (file.events[event.rawValue] ?? []).filter { group in
                event.usesToolMatcher || event == .sessionStart ? HookMatcher.matches(group.matcher, subject) : true
            }
        }
        return matched.flatMap(\.handlers).filter(\.isRunnable)
    }

    /// Every fitting hook at once (H7); their decisions together.
    func run(_ event: HookEvent, _ input: HookInput, projectRoot: URL?) async -> HookOutcome {
        let handlers = handlers(event, tool: input.toolName, projectRoot: projectRoot)
        guard !handlers.isEmpty else { return HookOutcome() }
        return await withTaskGroup(of: HookOutcome.self) { group in
            for handler in handlers {
                group.addTask { await HookEngine.run(handler, input: input, cwd: projectRoot) }
            }
            var outcome = HookOutcome()
            for await one in group { outcome.merge(one) }
            return outcome
        }
    }

    // MARK: Helpers

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func key(_ root: URL) -> String { root.standardizedFileURL.path }

    private func saveTrust() {
        guard let url = folder?.appendingPathComponent(Self.trustFileName), let data = try? JSONEncoder().encode(trusted) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
