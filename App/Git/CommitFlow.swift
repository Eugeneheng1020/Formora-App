import Foundation
import Observation

/// The commit sheet's state (user 2026-09-14: 提交 + 推送 + 发 PR from inside Formora): the changes, what's ticked, the
/// message, and the steps as they run. Every git call is one shell command the user could type themselves.
@MainActor
@Observable
final class CommitFlow {
    struct Outcome: Equatable, Sendable {
        var commit: String
        var branch: String
        var pushed: Bool
        var pullRequest: String?
    }

    let root: URL
    private let runner: GitRunner

    private(set) var status: GitStatus?
    /// The folder isn't a git repository (or git isn't there).
    private(set) var notRepo = false
    private(set) var loaded = false
    var selected: Set<String> = []
    var message = ""
    /// What runs now — `正在提交…`; `nil` when idle.
    private(set) var busy: String?
    private(set) var problem: String?
    private(set) var outcome: Outcome?
    private(set) var diffs: [String: String] = [:]
    private(set) var drafting = false
    /// The model writes the message from the files and their diff; `nil` when no model is configured.
    var draftMessage: (@MainActor ([String], String) async -> String?)?

    static let diffLimit = 200_000
    static let draftDiffLimit = 30_000

    init(root: URL, transport: GitRunner.Transport? = nil) {
        self.root = root
        runner = GitRunner(cwd: root, transport: transport)
    }

    var changes: [GitChange] { status?.changes ?? [] }
    var selectedChanges: [GitChange] { changes.filter { selected.contains($0.path) } }
    var canRun: Bool { busy == nil && !selectedChanges.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The branch, the upstream, the changes; the first time everything is ticked and the message gets its fallback.
    func refresh() async {
        let branch = await runner.run("git rev-parse --abbrev-ref HEAD")
        guard branch.succeeded else {
            notRepo = true
            status = nil
            loaded = true
            return
        }
        let upstream = await runner.run("git rev-parse --abbrev-ref --symbolic-full-name '@{u}'")
        let porcelain = await runner.run("git status --porcelain=v1 -z --untracked-files=all")
        let changes = Git.parseStatus(porcelain.stdout)
        status = GitStatus(branch: branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                           upstream: upstream.succeeded ? upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                           changes: changes)
        notRepo = false
        let paths = Set(changes.map(\.path))
        selected = loaded ? selected.intersection(paths) : paths
        if !loaded, message.isEmpty { message = Git.fallbackMessage(files: changes.map(\.path)) }
        loaded = true
        diffs = diffs.filter { paths.contains($0.key) }
    }

    /// The file's diff against HEAD (a new file: all of it), cached; capped so a huge file can't stall the sheet.
    func diff(of change: GitChange) async -> String {
        if let cached = diffs[change.path] { return cached }
        let command = change.kind == .untracked
            ? "git diff --no-index -- /dev/null \(Git.quoted(change.path))"
            : "git diff HEAD -- \(Git.quoted(change.path))"
        let result = await runner.run(command)
        var text = Git.stripHeader(result.stdout)
        if text.isEmpty, !result.stderr.isEmpty { text = result.stderr }
        if text.utf8.count > Self.diffLimit { text = String(text.prefix(Self.diffLimit)) + "\n… 太长，后面省略" }
        diffs[change.path] = text
        return text
    }

    /// 让 Agent 起草: the model reads the ticked files' diff and writes the message; without one, the fallback.
    func draft() async {
        let files = selectedChanges.map(\.path)
        guard !files.isEmpty else { return }
        drafting = true
        defer { drafting = false }
        var combined = ""
        for change in selectedChanges {
            let diff = await diff(of: change)
            combined += "--- \(change.path)\n" + diff + "\n"
            if combined.utf8.count > Self.draftDiffLimit { break }
        }
        if let draftMessage, let written = await draftMessage(files, String(combined.prefix(Self.draftDiffLimit))),
           !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = written.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = Git.fallbackMessage(files: files)
        }
    }

    /// Commit the ticked files; then push; then open the pull request. On a protected branch, work moves to a new
    /// branch first when it is going out. The first failure stops the rest and says why.
    func run(push: Bool, pullRequest: Bool, now: Date = Date()) async {
        guard canRun, let status else { return }
        problem = nil
        outcome = nil
        let files = selectedChanges.map(\.path)
        let (title, body) = Git.split(message)
        var branch = status.branch
        if push || pullRequest, Git.isProtected(branch) {
            branch = Git.branchName(for: title, now: now)
            busy = "正在建分支 \(branch)…"
            let made = await runner.run("git checkout -b \(Git.quoted(branch))")
            guard made.succeeded else { return fail(Git.explain(made, doing: "建分支")) }
        }
        busy = "正在提交…"
        let added = await runner.run("git add -A -- " + files.map(Git.quoted).joined(separator: " "))
        guard added.succeeded else { return fail(Git.explain(added, doing: "暂存")) }
        let messageFile = FileManager.default.temporaryDirectory.appendingPathComponent("formora-commit-\(UUID().uuidString).txt")
        do {
            try message.trimmingCharacters(in: .whitespacesAndNewlines).write(to: messageFile, atomically: true, encoding: .utf8)
        } catch {
            return fail("写不了提交信息：\(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: messageFile) }
        // Only the ticked files: everything else staged before stays out of this commit.
        let committed = await runner.run("git commit -F \(Git.quoted(messageFile.path)) -- " + files.map(Git.quoted).joined(separator: " "))
        guard committed.succeeded else { return fail(Git.explain(committed, doing: "提交")) }
        let hash = await runner.run("git rev-parse --short HEAD")
        var result = Outcome(commit: hash.stdout.trimmingCharacters(in: .whitespacesAndNewlines), branch: branch, pushed: false)
        AppLog.info("git", "提交 \(result.commit) 到 \(branch)：\(files.count) 个文件")
        if push || pullRequest {
            busy = "正在推送…"
            let pushed = await runner.run("git push -u origin HEAD")
            guard pushed.succeeded else {
                outcome = result
                return fail(Git.explain(pushed, doing: "推送"))
            }
            result.pushed = true
        }
        if pullRequest {
            busy = "正在发 PR…"
            let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("formora-pr-\(UUID().uuidString).md")
            try? (body.isEmpty ? "由 Formora 提交。" : body + "\n\n由 Formora 提交。").write(to: bodyFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            let opened = await runner.run("gh pr create --head \(Git.quoted(branch)) --title \(Git.quoted(title)) --body-file \(Git.quoted(bodyFile.path))")
            guard opened.succeeded, let url = Git.pullRequestURL(in: opened.stdout + "\n" + opened.stderr) else {
                outcome = result
                return fail(Git.explain(opened, doing: "发 PR"))
            }
            result.pullRequest = url
            AppLog.info("git", "PR \(url)")
        }
        outcome = result
        busy = nil
        await refresh()
    }

    private func fail(_ reason: String) {
        problem = reason
        busy = nil
        AppLog.warn("git", reason)
    }
}
