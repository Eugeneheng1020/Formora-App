import Darwin
import Foundation

/// Runs one command with bash (7c): a working folder, a deadline, the output kept. Stopping the run that asked for it
/// stops the command and everything it started. Hooks (7b′) run their commands here too.
enum Shell {
    struct Result: Equatable, Sendable {
        var exit: Int32?
        var stdout = ""
        var stderr = ""
        var timedOut = false
        /// It couldn't run, or it was stopped.
        var failure: String?
    }

    static let stopped = "用户停止了，命令已经结束。"
    /// Output kept per stream; beyond it the rest is read and dropped, so the command never blocks on a full pipe.
    static let captureLimit = 8 * 1024 * 1024

    /// The app's environment with Homebrew on the PATH (a sandboxed app starts with only the system's), and the
    /// project folder under Formora's name and Claude Code's, so scripts written for Claude Code keep working.
    static func environment(projectPath: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        if let projectPath {
            environment["FORMORA_PROJECT_DIR"] = projectPath
            environment["CLAUDE_PROJECT_DIR"] = projectPath
        }
        return environment
    }

    static func run(_ command: String, input: Data = Data(), cwd: URL?, timeout: TimeInterval, environment: [String: String]) async -> Result {
        let job = ShellJob()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: job.run(command, input: input, cwd: cwd, timeout: timeout, environment: environment))
                }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// One command, once. The lock guards what two threads touch: the output as it arrives, and whether it was stopped.
private final class ShellJob: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var isCancelled = false
    private var stdout = Data()
    private var stderr = Data()

    /// A command that doesn't read its input would otherwise take the app down with SIGPIPE.
    private static let ignoresBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    func cancel() { lock.withLock { isCancelled = true } }

    private var cancelled: Bool { lock.withLock { isCancelled } }

    func run(_ command: String, input data: Data, cwd: URL?, timeout: TimeInterval, environment: [String: String]) -> Shell.Result {
        _ = Self.ignoresBrokenPipes
        if cancelled { return Shell.Result(failure: Shell.stopped) }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return Shell.Result(failure: "运行不了：\(error.localizedDescription)")
        }
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            self.drain(self.output.fileHandleForReading) { chunk in self.lock.withLock { Self.append(chunk, to: &self.stdout) } }
            reading.leave()
        }
        reading.enter()
        DispatchQueue.global().async {
            self.drain(self.errors.fileHandleForReading) { chunk in self.lock.withLock { Self.append(chunk, to: &self.stderr) } }
            reading.leave()
        }
        DispatchQueue.global().async {
            try? self.input.fileHandleForWriting.write(contentsOf: data)
            try? self.input.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var stopped = false
        var graceEnds: Date?
        while reading.wait(timeout: .now() + 0.2) == .timedOut {
            if cancelled { stopped = true; break }
            if Date() >= deadline { timedOut = true; break }
            // The command ended, but something it started in the background still holds its output open: a moment
            // more for the last words, then stop waiting.
            if !process.isRunning {
                let ends = graceEnds ?? Date().addingTimeInterval(1)
                graceEnds = ends
                if Date() >= ends { break }
            }
        }
        if timedOut || stopped {
            Self.stopTree(process.processIdentifier)
            _ = reading.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        let (out, err) = lock.withLock { (stdout, stderr) }
        return Shell.Result(exit: timedOut || stopped ? nil : process.terminationStatus, stdout: String(decoding: out, as: UTF8.self),
                            stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut, failure: stopped ? Shell.stopped : nil)
    }

    private func drain(_ handle: FileHandle, _ keep: (Data) -> Void) {
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty { keep(chunk) }
    }

    private static func append(_ chunk: Data, to data: inout Data) {
        guard data.count < Shell.captureLimit else { return }
        data.append(chunk.prefix(Shell.captureLimit - data.count))
    }

    /// The command and everything it started — a dev server, a watcher — not just bash.
    private static func stopTree(_ pid: pid_t) {
        ProcessTree.signal(pid, SIGKILL)
    }
}

/// A process and everything it started (the bash tool, 7c; stdio MCP servers, 9d): `npx` starts node, node its workers.
enum ProcessTree {
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        func collect(_ parent: pid_t) {
            for child in children(of: parent) where !found.contains(child) {
                found.append(child)
                collect(child)
            }
        }
        collect(pid)
        return found
    }

    /// To the process and its descendants, collected first — once the parent is gone, its children are launchd's.
    static func signal(_ pid: pid_t, _ sig: Int32) {
        let tree = descendants(of: pid)
        kill(pid, sig)
        for child in tree { kill(child, sig) }
    }

    static func children(of pid: pid_t) -> [pid_t] {
        let needed = proc_listchildpids(pid, nil, 0)
        guard needed > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(needed) + 16)
        let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        return count > 0 ? buffer.prefix(Int(count)).filter { $0 > 0 } : []
    }
}
