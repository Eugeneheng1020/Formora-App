import Darwin
import Foundation
import Observation

/// 10f: commands that keep running after their call returns — a dev server, a watcher, a long build (omp's background
/// jobs, Codex's exec sessions). A job is its conversation's: its Agents read what it printed since they last looked
/// (`bash_output`) and stop it (`bash_stop`); one that ends while nobody is looking is told to the conversation.
/// Deleting the conversation or quitting Formora stops its jobs and everything they started.
@MainActor @Observable
final class BackgroundJobs {
    struct Job: Identifiable, Equatable, Sendable {
        let id: String
        let conversationID: UUID
        let command: String
        let startedAt: Date
        var endedAt: Date?
        /// `nil` once stopped.
        var exit: Int32?

        var isRunning: Bool { endedAt == nil }
    }

    private enum Stopper { case agent, user, gone }

    static let maxRunning = 8
    /// Ended jobs remembered, for a late `bash_output`.
    static let endedKept = 20

    /// How long starting one waits for it: one that ends by then comes back as an ordinary command (Codex's yield).
    @ObservationIgnored var firstWait: TimeInterval = 3
    /// A job ended while nobody was looking: the line for its conversation.
    @ObservationIgnored var onEnd: (Job, String) -> Void = { _, _ in }

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var processes: [String: JobProcess] = [:]
    @ObservationIgnored private var stoppers: [String: Stopper] = [:]
    /// Jobs a call is waiting on: their end is that call's answer, not a line.
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var counter = 0

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    func running(in conversationID: UUID) -> [Job] { jobs.filter { $0.conversationID == conversationID && $0.isRunning } }
    var runningCount: Int { jobs.filter(\.isRunning).count }
    /// Tests: the command's process.
    func pid(of id: String) -> pid_t? { processes[id]?.pid }

    // MARK: The tools

    static let output = ToolSpec(
        name: "bash_output",
        description: "Read what a background command (bash with background: true) printed since you last looked, and whether it is still running. wait: seconds to keep collecting before answering (at most 30) — for the end of a build or a test run; it answers as soon as the command ends.",
        parameters: #"{"type":"object","properties":{"id":{"type":"string","description":"The job's id, like j1"},"wait":{"type":"integer","description":"Seconds to wait for more output (0–30, default 0)"}},"required":["id"]}"#,
        tier: .read)

    static let stop = ToolSpec(
        name: "bash_stop",
        description: "Stop a background command and everything it started. Stop the ones you no longer need — a dev server once you're done with it.",
        parameters: #"{"type":"object","properties":{"id":{"type":"string","description":"The job's id, like j1"}},"required":["id"]}"#,
        tier: .read)

    static let specs = [output, stop]

    nonisolated static func wantsBackground(_ arguments: String) -> Bool {
        let value = ToolArguments.parse(arguments)?["background"]
        return value as? Bool == true || (value as? String)?.lowercased() == "true"
    }

    // MARK: Running

    /// Starts `command` in `cwd` and waits `firstWait` for it: ended by then, its output and code like any command;
    /// otherwise its id and what it printed so far.
    func start(_ command: String, in conversationID: UUID, cwd: URL) async -> ToolResult {
        guard runningCount < Self.maxRunning else {
            return .failed("已经有 \(Self.maxRunning) 条命令在后台运行，先用 bash_stop 停掉用不着的，再开新的。")
        }
        counter += 1
        let id = "j\(counter)"
        let process = JobProcess(command: command, cwd: cwd, environment: Shell.environment(projectPath: cwd.path))
        do {
            try process.start { [weak self] status in
                // A moment for the last words still in the pipe.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.ended(id, status: status)
                }
            }
        } catch {
            return .failed("运行不了：\(error.localizedDescription)")
        }
        processes[id] = process
        jobs.append(Job(id: id, conversationID: conversationID, command: command, startedAt: .now))
        watched.insert(id)
        defer { watched.remove(id) }
        let deadline = Date.now.addingTimeInterval(firstWait)
        while Date.now < deadline, job(id)?.isRunning == true {
            if Task.isCancelled {
                // 停止 while it was starting: it goes with the run.
                halt(id, by: .agent)
                return ToolResult(status: .stopped, output: Shell.stopped)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let text = process.unread().text
        guard let job = job(id), !job.isRunning else {
            return .done("已在后台运行，编号 \(id)。"
                         + (text.isEmpty ? "还没有输出。" : "到现在的输出：\n" + BashTool.trimmed(text, limit: BashTool.outputLimit))
                         + "\n用 bash_output 看之后的输出，用 bash_stop 停止；它自己结束时你会收到通知。")
        }
        forget(id)
        return BashTool.outcome(Shell.Result(exit: job.exit, stdout: text), timeout: 0)
    }

    /// A foreground command that stepped aside for the user's message (user 2026-09-17): the conversation's job from
    /// here on, read and stopped like one started with `background: true`. Already running, so `maxRunning` doesn't
    /// turn it away. Returns its id.
    func adopt(_ aside: Shell.Aside, command: String, in conversationID: UUID, cwd: URL) -> String {
        counter += 1
        let id = "j\(counter)"
        let process = JobProcess(adopting: aside.pid, command: command, cwd: cwd)
        processes[id] = process
        jobs.append(Job(id: id, conversationID: conversationID, command: command, startedAt: .now))
        aside.attach(output: { process.keep($0) }, exit: { [weak self] status in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self?.ended(id, status: status)
            }
        })
        return id
    }

    /// `bash_output`: what it printed since the last look, collected for `wait` seconds unless it ends first.
    func output(_ id: String, in conversationID: UUID, wait: TimeInterval) async -> ToolResult {
        guard let job = job(id), job.conversationID == conversationID, let process = processes[id] else { return unknown(id, in: conversationID) }
        if job.isRunning, wait > 0 {
            watched.insert(id)
            defer { watched.remove(id) }
            let deadline = Date.now.addingTimeInterval(min(wait, 30))
            while Date.now < deadline, !Task.isCancelled, self.job(id)?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let (text, skipped) = process.unread()
        var parts = [Self.state(of: self.job(id) ?? job)]
        if skipped > 0 { parts.append("（输出太多，中间有约 \(skipped) 字节没留下）") }
        parts.append(text.isEmpty ? "（没有新的输出）" : "新的输出：\n" + BashTool.trimmed(text, limit: BashTool.outputLimit))
        return .done(parts.joined(separator: "\n"))
    }

    /// `bash_stop`: the command and everything it started.
    func stop(_ id: String, in conversationID: UUID) async -> ToolResult {
        guard let job = job(id), job.conversationID == conversationID, let process = processes[id] else { return unknown(id, in: conversationID) }
        guard job.isRunning else { return .done(Self.state(of: job)) }
        halt(id, by: .agent)
        for _ in 0..<40 where self.job(id)?.isRunning == true { try? await Task.sleep(for: .milliseconds(50)) }
        let text = process.unread().text
        return .done("已停止 \(id)，连同它启动的进程。" + (text.isEmpty ? "" : "停下前的输出：\n" + BashTool.trimmed(text, limit: 4000)))
    }

    /// 停止 on the strip: the conversation is told.
    func stopByUser(_ id: String) { halt(id, by: .user) }

    /// The conversation is going: its jobs go too, untold.
    func stop(conversation id: UUID) {
        for job in running(in: id) { halt(job.id, by: .gone) }
    }

    /// Quitting: everything, now.
    func stopEverything() {
        for job in jobs where job.isRunning { halt(job.id, by: .gone) }
    }

    private func halt(_ id: String, by stopper: Stopper) {
        guard job(id)?.isRunning == true else { return }
        stoppers[id] = stopper
        processes[id]?.stop()
    }

    private func ended(_ id: String, status: Int32) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isRunning else { return }
        let stopper = stoppers.removeValue(forKey: id)
        jobs[index].endedAt = .now
        jobs[index].exit = stopper == nil ? status : nil
        let job = jobs[index]
        if !watched.contains(id), stopper == nil || stopper == .user, let process = processes[id] {
            onEnd(job, Self.note(job, output: process.unread().text, byUser: stopper == .user))
        }
        prune()
    }

    private func prune() {
        let ended = jobs.filter { !$0.isRunning }
        guard ended.count > Self.endedKept else { return }
        for job in ended.prefix(ended.count - Self.endedKept) { forget(job.id) }
    }

    private func forget(_ id: String) {
        jobs.removeAll { $0.id == id }
        processes[id] = nil
        stoppers[id] = nil
    }

    private func unknown(_ id: String, in conversationID: UUID) -> ToolResult {
        let mine = jobs.filter { $0.conversationID == conversationID }.map(\.id)
        return .failed("这个对话里没有编号为 \(id) 的后台命令。" + (mine.isEmpty ? "" : "有的：" + mine.joined(separator: "、")))
    }

    // MARK: Words

    static func state(of job: Job, now: Date = .now) -> String {
        guard let ended = job.endedAt else { return "\(job.id) 还在运行（已运行 \(elapsed(now.timeIntervalSince(job.startedAt)))）。" }
        guard let exit = job.exit else { return "\(job.id) 已停止。" }
        return "\(job.id) 已结束，退出码 \(exit)（运行了 \(elapsed(ended.timeIntervalSince(job.startedAt)))）。"
    }

    /// What the conversation reads of a job that ended unwatched.
    static func note(_ job: Job, output: String, byUser: Bool) -> String {
        let command = String((job.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? job.command).prefix(80))
        let head = byUser ? "〔用户停止了后台命令 \(job.id)（\(command)）" : "〔后台命令 \(job.id)（\(command)）已结束，退出码 \(job.exit ?? -1)"
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return head + (text.isEmpty ? "〕" : "。最后的输出：\n" + BashTool.trimmed(text, limit: 2000) + "\n〕")
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分 \(total % 60) 秒" }
        return "\(total / 3600) 小时 \(total % 3600 / 60) 分"
    }
}

/// One background command: its output as it comes — stdout and stderr together, in the order written — kept up to
/// `keepLimit` (the oldest goes first), and how much of it the model has been given.
final class JobProcess: @unchecked Sendable {
    static let keepLimit = 1 << 20

    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private let command: String
    private let cwd: URL
    private let environment: [String: String]
    private var kept = Data()
    /// Bytes gone from the front.
    private var dropped = 0
    /// Bytes the model has been given, counted from the start.
    private var readTo = 0

    /// A command that doesn't read its input would otherwise take the app down with SIGPIPE.
    private static let ignoresBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// A command started elsewhere and taken over while it runs (`BackgroundJobs.adopt`): its output is handed to `keep`.
    private let adopted: pid_t?

    init(command: String, cwd: URL, environment: [String: String]) {
        self.command = command
        self.cwd = cwd
        self.environment = environment
        adopted = nil
    }

    init(adopting pid: pid_t, command: String, cwd: URL) {
        self.command = command
        self.cwd = cwd
        environment = [:]
        adopted = pid
    }

    var pid: pid_t { adopted ?? process.processIdentifier }

    func start(onExit: @escaping @Sendable (Int32) -> Void) throws {
        _ = Self.ignoresBrokenPipes
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.keep(chunk)
        }
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
    }

    func keep(_ chunk: Data) {
        lock.withLock {
            kept.append(chunk)
            guard kept.count > Self.keepLimit else { return }
            let cut = kept.count - Self.keepLimit * 3 / 4
            kept = Data(kept.dropFirst(cut))
            dropped += cut
        }
    }

    /// What arrived since the last read, and how many bytes of it were dropped unread.
    func unread() -> (text: String, skipped: Int) {
        lock.withLock {
            let from = max(readTo, dropped)
            let skipped = from - readTo
            let text = String(decoding: kept.dropFirst(from - dropped), as: UTF8.self)
            readTo = dropped + kept.count
            return (text, skipped)
        }
    }

    /// The command and everything it started — a dev server's workers, a watcher's children.
    func stop() {
        // An adopted one: `BackgroundJobs.halt` only comes here while the job still runs.
        guard adopted != nil || process.isRunning else { return }
        ProcessTree.signal(pid, SIGKILL)
    }
}
