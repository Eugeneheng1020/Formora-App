import Foundation

/// One host of one provider, and how to talk to it.
struct ProviderEndpoint: Equatable, Sendable {
    let baseURL: String
    let apiProtocol: APIProtocol
    var keyCheckPath: String?
    var notFoundMeansAuthorized = false

    func request(_ path: String, key: String) -> URLRequest? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.host != nil else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: ProviderClient.timeout)
        switch apiProtocol {
        case .openAICompletions, .openAIResponses:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropicMessages:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .googleGenerativeAI:
            // A header, not `?key=`: the key must not end up in a URL that could be logged.
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }
}

enum ConnectionOutcome: Equatable, Sendable {
    case connected(note: String?)
    case invalidKey(String?)
    case notFound
    case timedOut
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum ModelListResult: Equatable, Sendable {
    case models([ModelInfo])
    /// The provider accepted the key but has no list endpoint.
    case unsupported
    case failed(ConnectionOutcome)
}

/// Key checks and model lists over HTTP (S14). Stateless; the transport is injectable for tests.
struct ProviderClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Design spec §8.4 uses 10 s for connection tests; the same here.
    static let timeout: TimeInterval = 10

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        return URLSession(configuration: configuration)
    }()

    static let live: Transport = { request in try await session.data(for: request) }

    let transport: Transport

    init(transport: @escaping Transport = ProviderClient.live) {
        self.transport = transport
    }

    func check(_ endpoint: ProviderEndpoint, key: String) async -> ConnectionOutcome {
        guard let request = endpoint.request(endpoint.keyCheckPath ?? endpoint.apiProtocol.modelsPath, key: key) else {
            return .failed("Base URL 无效")
        }
        do {
            let (data, response) = try await transport(request)
            return Self.interpret(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, endpoint: endpoint)
        } catch {
            return Self.outcome(for: error)
        }
    }

    func models(_ endpoint: ProviderEndpoint, key: String) async -> ModelListResult {
        guard let request = endpoint.request(endpoint.apiProtocol.modelsPath, key: key) else {
            return .failed(.failed("Base URL 无效"))
        }
        do {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                if status == 404, endpoint.notFoundMeansAuthorized { return .unsupported }
                return .failed(Self.interpret(status: status, body: data, endpoint: endpoint))
            }
            guard let models = Self.parseModels(data, apiProtocol: endpoint.apiProtocol) else {
                return .failed(.failed("模型列表的格式无法识别"))
            }
            return .models(models)
        } catch {
            return .failed(Self.outcome(for: error))
        }
    }

    // MARK: Interpretation

    /// S14. Probed 2026-09-11: Google and xAI answer a bad key with 400, everyone else with 401.
    static func interpret(status: Int, body: Data, endpoint: ProviderEndpoint) -> ConnectionOutcome {
        let message = providerMessage(from: body)
        switch status {
        case 200..<300:
            return .connected(note: nil)
        case 401, 403:
            return .invalidKey(message)
        case 400:
            let text = (message ?? "").lowercased()
            if text.contains("api key") || text.contains("api_key") || text.contains("apikey") { return .invalidKey(message) }
            return .failed(message ?? "请求被拒绝（400）")
        case 404:
            return endpoint.notFoundMeansAuthorized ? .connected(note: "这家服务商不提供模型列表") : .notFound
        case 429:
            return .connected(note: "Key 有效，但当前请求过多（429）")
        default:
            return .failed(message ?? "服务返回 \(status)")
        }
    }

    static func outcome(for error: Error) -> ConnectionOutcome {
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timedOut }
        return .failed(error.localizedDescription)
    }

    /// The provider's own words: `{"error":{"message":…}}`, `{"error":"…"}` or `{"message":…}`.
    static func providerMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let raw: String? = if let error = object["error"] as? [String: Any] {
            error["message"] as? String
        } else {
            (object["error"] as? String) ?? (object["message"] as? String)
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(200))
    }

    /// Three shapes (old app 2026-09-05): OpenAI-compatible and Anthropic `{"data":[{"id":…}]}`, Google
    /// `{"models":[{"name":"models/…"}]}`. Google's list mixes in embedding and tuning models that can't
    /// chat — only models offering `generateContent` are kept.
    static func parseModels(_ data: Data, apiProtocol: APIProtocol) -> [ModelInfo]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if apiProtocol == .googleGenerativeAI {
            guard let list = object["models"] as? [[String: Any]] else { return nil }
            return list.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                if let methods = item["supportedGenerationMethods"] as? [String], !methods.contains("generateContent") { return nil }
                return ModelInfo(id: name.hasPrefix("models/") ? String(name.dropFirst(7)) : name,
                                 name: item["displayName"] as? String,
                                 contextWindow: item["inputTokenLimit"] as? Int,
                                 maxOutput: item["outputTokenLimit"] as? Int)
            }
        }
        guard let list = object["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return ModelInfo(id: id,
                             name: (item["display_name"] as? String) ?? (item["name"] as? String),
                             contextWindow: (item["context_length"] as? Int) ?? (item["context_window"] as? Int),
                             acceptsImages: takesImages(item))
        }
    }

    /// What a list says a model takes in (7j, V2): `input_modalities`, OpenRouter's `architecture.input_modalities`,
    /// or `modalities.input`. `nil` when it doesn't say — the catalog may know.
    private static func takesImages(_ item: [String: Any]) -> Bool? {
        let inputs = (item["input_modalities"] as? [String])
            ?? ((item["architecture"] as? [String: Any])?["input_modalities"] as? [String])
            ?? ((item["modalities"] as? [String: Any])?["input"] as? [String])
        return inputs.map { $0.contains("image") }
    }
}
