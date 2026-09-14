import Foundation

/// 一键提交 (user 2026-09-14): the project folder's git, run through the user's own login shell — their git, their PATH,
/// their proxy and credentials, exactly as in Terminal. Nothing here asks a model.
struct GitChange: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case modified, added, deleted, renamed, untracked, conflicted, other

        var mark: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "?"
            case .conflicted: "!"
            case .other: "·"
            }
        }

        var label: String {
            switch self {
            case .modified: "改动"
            case .added: "新增"
            case .deleted: "删除"
            case .renamed: "改名"
            case .untracked: "新文件"
            case .conflicted: "冲突"
            case .other: "其他"
            }
        }
    }

    let path: String
    let kind: Kind
    /// A rename's old path.
    var from: String?

    var id: String { path }
}

struct GitStatus: Equatable, Sendable {
    var branch: String
    var upstream: String?
    var changes: [GitChange]
}

enum Git {
    /// `git status --porcelain=v1 -z`: `XY path\0`, a rename as `R  new\0old\0`.
    static func parseStatus(_ output: String) -> [GitChange] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var changes: [GitChange] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            index += 1
            guard field.count >= 4 else { continue }
            let x = field[field.startIndex], y = field[field.index(after: field.startIndex)]
            let path = String(field.dropFirst(3))
            var from: String?
            let kind: GitChange.Kind
            if x == "?" {
                kind = .untracked
            } else if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
                kind = .conflicted
            } else if x == "R" || y == "R" {
                kind = .renamed
                if index < fields.count { from = fields[index]; index += 1 }
            } else if x == "A" || y == "A" {
                kind = .added
            } else if x == "D" || y == "D" {
                kind = .deleted
            } else if x == "M" || y == "M" || x == "T" || y == "T" {
                kind = .modified
            } else {
                kind = .other
            }
            changes.append(GitChange(path: path, kind: kind, from: from))
        }
        return changes
    }

    /// `main`, `master`, `develop`, `release/*`: work goes on a branch of its own first.
    static func isProtected(_ branch: String) -> Bool {
        ["main", "master", "develop", "trunk"].contains(branch) || branch.hasPrefix("release/")
    }

    /// `formora/会员等级-0914-2231`: the task's name, ASCII kept, spaces to dashes, and the minute so it never repeats.
    static func branchName(for title: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmm"
        var slug = ""
        for scalar in title.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || ("\u{4E00}"..."\u{9FFF}").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "formora/" + (slug.isEmpty ? "work" : slug) + "-" + formatter.string(from: now)
    }

    /// The commit message when no model drafts one: the files, in one line.
    static func fallbackMessage(files: [String]) -> String {
        let names = files.map { ($0 as NSString).lastPathComponent }
        switch names.count {
        case 0: return ""
        case 1: return "更新 \(names[0])"
        case 2, 3: return "更新 " + names.joined(separator: "、")
        default: return "更新 \(names[0]) 等 \(names.count) 个文件"
        }
    }

    /// The first line is the title; the rest the body.
    static func split(_ message: String) -> (title: String, body: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(of: "\n") else { return (trimmed, "") }
        return (String(trimmed[..<newline]).trimmingCharacters(in: .whitespaces),
                String(trimmed[trimmed.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The hunks only: `DiffText` draws the first character of a line as its mark, so git's header lines (`diff --git`,
    /// `index`, `---`, `+++`, modes, renames) would lose a letter each. Binary files say so in one line.
    static func stripHeader(_ diff: String) -> String {
        let headers = ["diff --git ", "index ", "--- ", "+++ ", "new file mode ", "deleted file mode ", "old mode ", "new mode ",
                       "similarity index ", "rename from ", "rename to ", "copy from ", "copy to "]
        var lines: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if headers.contains(where: { text.hasPrefix($0) }) { continue }
            if text.hasPrefix("Binary files ") { lines.append(" （二进制文件）"); continue }
            lines.append(text)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// A shell word: single-quoted, a quote inside as `'\''`.
    static func quoted(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `https://…` gh prints when it opened the pull request.
    static func pullRequestURL(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("https://") && $0.contains("/pull/") }
    }

    /// Tells the user what the tool needs, in their words.
    static func explain(_ result: GitRunner.Result, doing what: String) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("command not found: gh") || text.contains("gh: command not found") {
            return "没找到 gh 命令。装法：brew install gh，然后 gh auth login 登录 GitHub。"
        }
        if text.contains("gh auth login") || text.contains("not logged into") {
            return "gh 还没登录 GitHub：在终端里运行 gh auth login。"
        }
        if text.contains("Permission denied (publickey)") || text.contains("could not read Username") || text.contains("Authentication failed") {
            return "推送没有权限：终端里能 git push 的话这里也能，先在终端里配好 SSH 或 HTTPS 登录。"
        }
        if text.contains("Could not resolve host") || text.contains("Failed to connect") || text.contains("timed out") {
            return "连不上 GitHub：检查网络或代理（Formora 用的是登录 shell 里的代理设置）。"
        }
        if text.contains("nothing to commit") { return "没有可提交的改动。" }
        return "\(what)失败：" + (text.isEmpty ? "退出码 \(result.exit.map(String.init) ?? "?")" : String(text.suffix(400)))
    }
}

/// Runs a command line through `/bin/zsh -lc` in a folder and collects what came back.
struct GitRunner: Sendable {
    struct Result: Equatable, Sendable {
        var exit: Int32?
        var stdout = ""
        var stderr = ""

        var succeeded: Bool { exit == 0 }
    }

    let cwd: URL
    var timeout: TimeInterval = 120

    /// Formora's tests: the commands in order, answered from a script.
    typealias Transport = @Sendable (_ command: String, _ cwd: URL) async -> Result

    var transport: Transport?

    func run(_ command: String) async -> Result {
        if let transport { return await transport(command, cwd) }
        return await Self.execute(command, cwd: cwd, timeout: timeout)
    }

    static func execute(_ command: String, cwd: URL, timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.currentDirectoryURL = cwd
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GH_PROMPT_DISABLED"] = "1"
                environment["GH_NO_UPDATE_NOTIFIER"] = "1"
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(exit: nil, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: Result(exit: process.terminationStatus,
                                                      stdout: String(decoding: stdout, as: UTF8.self),
                                                      stderr: String(decoding: stderr, as: UTF8.self)))
            }
        }
    }
}
