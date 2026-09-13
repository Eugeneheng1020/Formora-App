import CryptoKit
import Foundation
import Network

/// PKCE (RFC 7636, S256).
enum PKCE {
    /// 43–128 characters from the unreserved set; 32 random bytes base64url-encoded give 43.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The browser sign-in's way back: a one-shot HTTP listener on 127.0.0.1 at a random port (codex
/// `perform_oauth_login.rs`, omp `oauth-flow.ts`). It answers exactly one valid callback with a page saying
/// the sign-in is done, then stops. Needs the `network.server` entitlement (old app 2026-09-07).
final class OAuthLoopback: @unchecked Sendable {
    enum Callback: Equatable, Sendable {
        case success(code: String, state: String)
        case denied(String)
        case invalid
    }

    static let callbackPath = "/callback"

    private let queue = DispatchQueue(label: "com.eugenecheng.formora.oauth-loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Callback, Never>?
    private var finished: Callback?
    /// `nil`: any free port. ChatGPT's client only returns to 1455 (7i).
    private let port: UInt16?
    let path: String
    private let redirectHost: String

    init(port: UInt16? = nil, path: String = OAuthLoopback.callbackPath, redirectHost: String = "127.0.0.1") {
        self.port = port
        self.path = path
        self.redirectHost = redirectHost
    }

    /// Starts listening; returns the redirect URI to register and send.
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard once.claim(), let port = listener.port?.rawValue else { return }
                    continuation.resume(returning: URL(string: "http://\(self.redirectHost):\(port)\(self.path)")!)
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to come back; `.denied` carries the provider's error.
    func waitForCallback(timeout: TimeInterval = 300) async -> Callback {
        let result = await withTaskGroup(of: Callback.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.lock.withLock {
                        if let finished = self.finished { continuation.resume(returning: finished) } else { self.continuation = continuation }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .denied("等待浏览器登录超时")
            }
            let first = await group.next() ?? .invalid
            group.cancelAll()
            return first
        }
        stop()
        return result
    }

    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
            if let continuation {
                continuation.resume(returning: finished ?? .denied("登录已取消"))
                self.continuation = nil
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let callback = Self.parse(requestLine: requestLine, path: self.path)
            let page: String
            switch callback {
            case .success: page = "登录完成，可以回到 Formora 了。"
            case .denied(let reason): page = "登录没有完成：\(reason)"
            case .invalid: page = "这不是 Formora 等待的登录回跳。"
            }
            let body = Data("<!doctype html><meta charset=utf-8><title>Formora</title><body style=\"font:15px -apple-system;padding:40px\">\(page)</body>".utf8)
            let head = "HTTP/1.1 \(callback == .invalid ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            guard callback != .invalid else { return }
            self.lock.withLock {
                guard self.finished == nil else { return }
                self.finished = callback
                self.continuation?.resume(returning: callback)
                self.continuation = nil
            }
        }
    }

    /// `GET /callback?code=…&state=… HTTP/1.1` → the result. Anything else is `.invalid` and ignored.
    static func parse(requestLine: String, path: String = callbackPath) -> Callback {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == path else { return .invalid }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if let error = items["error"] {
            return .denied(items["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error)
        }
        guard let code = items["code"], !code.isEmpty, let state = items["state"], !state.isEmpty else { return .invalid }
        return .success(code: code, state: state)
    }
}

/// A thread-safe "first caller wins" flag.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
