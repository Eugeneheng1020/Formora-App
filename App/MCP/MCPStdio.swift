import Darwin
import Foundation

/// Where commands are found (9d, S2): the login shell's PATH, read once — an app opened from the Dock starts with only
/// the system's, while `npx` from npm's own folder or nvm, `python3` from python.org live elsewhere — Homebrew's added.
enum ShellPath {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: (path: String, proxies: [String: String])?

    /// Blocks up to 5 seconds the first time: call it off the main thread.
    static func value() -> String { login().path }

    /// The proxy variables the login sets (9d): where the network only goes out through a proxy, a server can't
    /// download itself (`npx -y`) without them, and an app opened from the Dock has none.
    static func proxies() -> [String: String] { login().proxies }

    private static func login() -> (path: String, proxies: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        let shell = loginShell()
        let system = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let value = (merged([shell.path ?? "", "/opt/homebrew/bin:/usr/local/bin", system]), shell.proxies)
        resolved = value
        return value
    }

    /// Joined in order, each folder once.
    static func merged(_ paths: [String]) -> String {
        var seen = Set<String>()
        return paths.flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// `$SHELL -ilc`: the PATH and the environment printed between markers, so whatever the profile prints is left out;
    /// nothing after 5 seconds.
    static func loginShell() -> (path: String?, proxies: [String: String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", #"printf '__FORMORA_PATH__%s__FORMORA_END__' "$PATH"; printf '__FORMORA_ENV__\n'; env; printf '__FORMORA_ENVEND__'"#]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return (nil, [:])
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return (nil, [:])
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (between(text), proxies(in: text))
    }

    static let proxyNames: Set<String> = ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]

    /// The proxy variables of an `env` printed between the markers, spelled as they were.
    static func proxies(in text: String) -> [String: String] {
        guard let start = text.range(of: "__FORMORA_ENV__"),
              let end = text.range(of: "__FORMORA_ENVEND__", range: start.upperBound..<text.endIndex) else { return [:] }
        var found: [String: String] = [:]
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals])
            if proxyNames.contains(name.lowercased()) { found[name] = String(line[line.index(after: equals)...]) }
        }
        return found
    }

    static func between(_ text: String) -> String? {
        guard let start = text.range(of: "__FORMORA_PATH__"),
              let end = text.range(of: "__FORMORA_END__", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// The command's file: a path as written (relative to `cwd`), else the first executable of that name on `path`.
    static func resolve(_ command: String, path: String, cwd: URL) -> URL? {
        if command.contains("/") {
            let url = command.hasPrefix("/") ? URL(fileURLWithPath: command) : cwd.appendingPathComponent(command)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for folder in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// What a stdio server's process gets (9d, S3), as codex hands its servers (`DEFAULT_ENV_VARS`): the login's PATH, a
/// handful of Formora's own variables, the login's proxy settings (unlike codex: a network that only goes out through a
/// proxy — this Mac's — can't download a server without them) and the server's own — nothing else leaks through.
enum MCPStdioEnvironment {
    static let passed = ["HOME", "LOGNAME", "PATH", "SHELL", "USER", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "TERM", "TMPDIR", "TZ"]

    static func make(server: [String: String], path: String, proxies: [String: String] = [:],
                     base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment: [String: String] = [:]
        for name in passed { if let value = base[name] { environment[name] = value } }
        for (name, value) in proxies { environment[name] = value }
        environment["PATH"] = path
        if environment["LANG"] == nil, environment["LC_ALL"] == nil { environment["LANG"] = "en_US.UTF-8" }
        for (name, value) in server { environment[name] = value }
        return environment
    }
}

/// One running stdio server (9d, S4): JSON-RPC messages, one per line, on its stdin and stdout; its stderr kept for
/// when something goes wrong. Requests overlap, each answered by its id. One lock guards what the reading threads share;
/// writing has its own, so a full pipe never holds up the reading.
final class MCPStdioConnection: @unchecked Sendable {
    let fingerprint: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let writing = NSLock()
    /// Both readers: an exit waits a moment for their last lines.
    private let readers = DispatchGroup()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var abandoned: Set<Int> = []
    private var nextID = 1
    private var errorLines: [String] = []
    private var hasExited = false
    private var introduced: (serverName: String?, version: String)?

    static let keptErrorLines = 40
    private static let ignoresBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    var pid: pid_t { process.processIdentifier }
    var isAlive: Bool { !lock.withLock { hasExited } && process.isRunning }
    var serverName: String? { lock.withLock { introduced?.serverName } }
    var protocolVersion: String { lock.withLock { introduced?.version } ?? MCPClient.protocolVersion }
    /// The server's last words on stderr: why it didn't start, most often.
    var errorTail: String { lock.withLock { errorLines.suffix(8).joined(separator: "\n") } }

    /// Starts it; throws when the command can't be found or run. Blocks on the login shell's PATH the first time.
    func launch(command: String, arguments: [String], serverEnvironment: [String: String], cwd: URL) throws {
        _ = Self.ignoresBrokenPipes
        let path = ShellPath.value()
        guard let executable = ShellPath.resolve(command, path: path, cwd: cwd) else {
            throw MCPFailure.network("找不到命令「\(command)」。在终端里能运行它吗？装好之后再测试连接。")
        }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = MCPStdioEnvironment.make(server: serverEnvironment, path: path, proxies: ShellPath.proxies())
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in self?.didExit() }
        do {
            try process.run()
        } catch {
            throw MCPFailure.network("启动不了「\(command)」：\(error.localizedDescription)")
        }
        read(output.fileHandleForReading) { [weak self] line in self?.receive(line) }
        read(errors.fileHandleForReading) { [weak self] line in self?.keepError(line) }
    }

    /// initialize, then notifications/initialized: the server's name, and the version agreed on.
    func initialize(timeout: TimeInterval) async throws {
        let answer = try await request("initialize", params: .object([
            "protocolVersion": .string(MCPClient.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Formora"),
                                   "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")]),
        ]), timeout: timeout)
        lock.withLock { introduced = (answer["serverInfo"]?["name"]?.string, answer["protocolVersion"]?.string ?? MCPClient.protocolVersion) }
        notify("notifications/initialized")
    }

    /// One request and its answer's `result`, within `timeout`.
    func request(_ method: String, params: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        let answer = try await withThrowingTaskGroup(of: JSONValue.self) { group -> JSONValue in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                        if self.register(id, continuation) { self.write(message) }
                    }
                } onCancel: {
                    self.abandon(id)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPFailure.network("\(Int(timeout)) 秒内没有响应")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MCPFailure.network("没有响应") }
            return first
        }
        if let error = answer["error"] { throw MCPFailure.protocolError(error["message"]?.string ?? "服务返回了错误") }
        guard let result = answer["result"] else { throw MCPFailure.protocolError("缺少 result") }
        return result
    }

    func notify(_ method: String) {
        write(.object(["jsonrpc": .string("2.0"), "method": .string(method)]))
    }

    /// Closes its input and gives it 2 seconds; then the process and what it started are terminated, and killed after
    /// 2 more (S4).
    func stop() {
        writing.withLock { try? input.fileHandleForWriting.close() }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            self.waitForExit(2)
            guard self.process.isRunning else { return }
            ProcessTree.signal(pid, SIGTERM)
            self.waitForExit(2)
            if self.process.isRunning { ProcessTree.signal(pid, SIGKILL) }
        }
    }

    /// At quit there's no time to wait: terminated now, killed a moment later.
    func stopNow() {
        writing.withLock { try? input.fileHandleForWriting.close() }
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        let tree = ProcessTree.descendants(of: pid)
        kill(pid, SIGTERM)
        for child in tree { kill(child, SIGTERM) }
        waitForExit(0.3)
        kill(pid, SIGKILL)
        for child in tree { kill(child, SIGKILL) }
    }

    // MARK: Inside

    private func waitForExit(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < end { usleep(50_000) }
    }

    /// `false` when the answer can't come: the request was given up already, or the server is gone.
    private func register(_ id: Int, _ continuation: CheckedContinuation<JSONValue, Error>) -> Bool {
        lock.lock()
        if abandoned.remove(id) != nil {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        if hasExited {
            let tail = errorLines.suffix(8).joined(separator: "\n")
            lock.unlock()
            continuation.resume(throwing: Self.exitFailure(tail))
            return false
        }
        pending[id] = continuation
        lock.unlock()
        return true
    }

    private func abandon(_ id: Int) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        if continuation == nil { abandoned.insert(id) }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func write(_ message: JSONValue) {
        var data = message.encoded()
        data.append(0x0A)
        writing.withLock { try? input.fileHandleForWriting.write(contentsOf: data) }
    }

    private func receive(_ line: String) {
        // A line that isn't JSON is the server printing to stdout by mistake: not a message.
        guard let message = JSONValue.parse(line) else { return }
        for item in message.array ?? [message] {
            if let method = item["method"]?.string {
                // A request of the server's own (roots, sampling, elicitation): Formora offers none of them.
                if let id = item["id"] {
                    write(.object(["jsonrpc": .string("2.0"), "id": id,
                                   "error": .object(["code": .number(-32601), "message": .string("Formora 不支持 \(method)")])]))
                }
                continue
            }
            guard let id = item["id"]?.int else { continue }
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            continuation?.resume(returning: item)
        }
    }

    private func keepError(_ line: String) {
        lock.withLock {
            errorLines.append(line)
            if errorLines.count > Self.keptErrorLines { errorLines.removeFirst(errorLines.count - Self.keptErrorLines) }
        }
    }

    private func didExit() {
        // Its last lines — an answer written just before, the reason on stderr — first.
        _ = readers.wait(timeout: .now() + 0.5)
        lock.lock()
        hasExited = true
        let waiting = pending
        pending = [:]
        let tail = errorLines.suffix(8).joined(separator: "\n")
        lock.unlock()
        let failure = Self.exitFailure(tail)
        for continuation in waiting.values { continuation.resume(throwing: failure) }
    }

    static func exitFailure(_ tail: String) -> MCPFailure {
        .network("服务进程退出了" + (tail.isEmpty ? "" : "：\n" + tail))
    }

    private func read(_ handle: FileHandle, _ each: @escaping @Sendable (String) -> Void) {
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            // What is there now, not a full 64 KB: a server answers a line at a time and waits (read(upToCount:) waits
            // for the count or the end, and a server that stays up never ends).
            while case let chunk = handle.availableData, !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    each(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            if !buffer.isEmpty { each(String(decoding: buffer, as: UTF8.self)) }
            self.readers.leave()
        }
    }
}

/// The stdio servers running now, one per server (9d, S4): started on first use and kept, started again when one died
/// or its command, environment or folder changed; stopped when the server is disabled, edited or deleted, and at quit.
@MainActor
final class MCPStdioPool {
    /// A first `npx -y` downloads its package (S5).
    nonisolated static let startTimeout: TimeInterval = 60

    private var running: [String: MCPStdioConnection] = [:]
    private var starting: [String: Task<MCPStdioConnection, Error>] = [:]

    func connection(for server: MCPServerConfig, environment: [String: String], cwd: URL,
                    timeout: TimeInterval = MCPStdioPool.startTimeout) async throws -> MCPStdioConnection {
        guard case .stdio(let command, let arguments) = server.transport else { throw MCPFailure.protocolError("不是 stdio 服务") }
        let fingerprint = ([command] + arguments + [cwd.path] + environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
            .joined(separator: "\u{1F}")
        if let live = running[server.id], live.fingerprint == fingerprint, live.isAlive { return live }
        if let task = starting[server.id] { return try await task.value }
        running.removeValue(forKey: server.id)?.stop()
        let task = Task<MCPStdioConnection, Error> {
            let connection = MCPStdioConnection(fingerprint: fingerprint)
            try await Task.detached {
                try connection.launch(command: command, arguments: arguments, serverEnvironment: environment, cwd: cwd)
            }.value
            do {
                try await connection.initialize(timeout: timeout)
            } catch {
                connection.stop()
                let message = (error as? MCPFailure)?.message ?? error.localizedDescription
                let tail = connection.errorTail
                throw MCPFailure.network(tail.isEmpty || message.contains(tail) ? message : message + "\n" + tail)
            }
            return connection
        }
        starting[server.id] = task
        defer { starting[server.id] = nil }
        let connection = try await task.value
        running[server.id] = connection
        return connection
    }

    func stop(_ id: String) {
        starting[id]?.cancel()
        running.removeValue(forKey: id)?.stop()
    }

    /// At quit.
    func stopAllNow() {
        for connection in running.values { connection.stopNow() }
        running = [:]
    }
}

extension MCPClient {
    /// Every tool of a running stdio server (9d), paged as over HTTP.
    static func listTools(on connection: MCPStdioConnection, timeout: TimeInterval = MCPStdioPool.startTimeout) async -> Result<MCPListing, MCPFailure> {
        do {
            var tools: [MCPTool] = []
            var cursor: String?
            var pages = 0
            repeat {
                let result = try await connection.request("tools/list", params: cursor.map { .object(["cursor": .string($0)]) } ?? .object([:]),
                                                          timeout: timeout)
                tools += (result["tools"]?.array ?? []).compactMap(Session.tool)
                cursor = result["nextCursor"]?.string
                pages += 1
            } while cursor != nil && pages < 50
            return .success(MCPListing(serverName: connection.serverName, protocolVersion: connection.protocolVersion, tools: tools))
        } catch {
            return .failure(error as? MCPFailure ?? .network(error.localizedDescription))
        }
    }

    /// One tool call on a running stdio server (7f, F3; 9d).
    static func callTool(on connection: MCPStdioConnection, name: String, arguments: String,
                         timeout: TimeInterval = MCPClient.callTimeout) async -> Result<MCPCallResult, MCPFailure> {
        let text = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = JSONValue.parse(text.isEmpty ? "{}" : text), case .object = parsed else {
            return .failure(.protocolError("参数不是 JSON 对象"))
        }
        do {
            let result = try await connection.request("tools/call", params: .object(["name": .string(name), "arguments": parsed]), timeout: timeout)
            return .success(MCPCallResult.from(result))
        } catch {
            return .failure(error as? MCPFailure ?? .network(error.localizedDescription))
        }
    }
}
