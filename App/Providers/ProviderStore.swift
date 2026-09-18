import AppKit
import Foundation
import Observation

enum ProviderStatus: Equatable, Sendable {
    case unconfigured, configured, testing
    case connected(note: String?)
    case invalid(String)
    case timedOut
    case failed(String)

    init(_ outcome: ConnectionOutcome) {
        switch outcome {
        case .connected(let note): self = .connected(note: note)
        case .invalidKey(let message): self = .invalid(message.map { "API Key 无效：\($0)" } ?? "API Key 无效")
        case .notFound: self = .failed("地址不对（404），请检查 Base URL 和 API 协议")
        case .timedOut: self = .timedOut
        case .failed(let message): self = .failed(message)
        }
    }

    /// The mockup's `PROVIDER_STATUS_LABEL`.
    var label: String {
        switch self {
        case .unconfigured: "未配置"
        case .configured: "已配置"
        case .testing: "测试中…"
        case .connected: "已连接"
        case .invalid, .failed: "连接异常"
        case .timedOut: "连接超时"
        }
    }

    var detail: String? {
        switch self {
        case .connected(let note): return note
        case .invalid(let message), .failed(let message): return message
        case .timedOut: return "\(Int(ProviderClient.timeout)) 秒内没有响应"
        case .unconfigured, .configured, .testing: return nil
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum ModelListState: Equatable, Sendable {
    case loading
    case loaded([ModelInfo])
    case unsupported
    case failed(String)
}

/// One row of 设置 → 模型, built-in or custom.
struct ProviderEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mark: String
    let logo: String?
    let isCustom: Bool
    let apiProtocol: APIProtocol
    let hosts: [ProviderHost]
    let commonModels: [ModelInfo]
    /// omp's catalog for this provider, the featured first; empty for a custom platform (user 2026-09-18).
    var catalogModels: [ModelInfo] = []
    var keyCheckPath: String?
    var notFoundMeansAuthorized = false
    var access: ProviderAccess = .key
    var tag: String?

    var baseURL: String { hosts.first?.baseURL ?? "" }
}

struct CustomProviderDraft: Equatable, Sendable {
    var name = ""
    var baseURL = ""
    var apiProtocol: APIProtocol = .openAICompletions
    var key = ""
}

enum ProviderFormProblem: Error, Equatable, Sendable {
    case keyRequired, nameRequired, nameTaken, badURL
    /// Agents still use it as primary or fallback model (spec §7.4, §8.7 rule 2).
    case inUse(Int)

    /// The mockup's wording (`saveProviderConfiguration`); spec §7.4 for `inUse`.
    var message: String {
        switch self {
        case .keyRequired: "API Key 为必填项"
        case .nameRequired: "服务商名称为必填项"
        case .nameTaken: "服务商名称已存在"
        case .badURL: "请输入以 http:// 或 https:// 开头的有效 Base URL"
        case .inUse(let count): "请先改掉 \(count) 个 Agent 的模型配置"
        }
    }
}

/// 设置 → 模型: built-in and custom providers, their keys (Keychain), connection status and model lists.
/// Statuses and model lists live only for this run (S11, S16).
@MainActor
@Observable
final class ProviderStore {
    private(set) var config: ProviderConfig
    private(set) var statuses: [String: ProviderStatus] = [:]
    private(set) var modelLists: [String: ModelListState] = [:]
    /// Providers whose host gives no list: their list is omp's catalog alone (user 2026-09-18), so 测试连接 can't
    /// confirm a model with the host.
    private(set) var catalogOnly: Set<String> = []
    /// Subscription sign-ins under way (7i, U1).
    private(set) var signIns: [String: SignInProgress] = [:]
    /// Opens the browser for a sign-in; tests hand in their own.
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// QA: the ChatGPT backend's address, pointed at the local fake server.
    @ObservationIgnored var chatGPTBase: String?
    @ObservationIgnored private var loopback: OAuthLoopback?

    /// How many Agents use a provider (primary or fallback); wired to `AgentStore` at launch.
    @ObservationIgnored var usage: (String) -> Int = { _ in 0 }
    @ObservationIgnored private var keyCache: [String: String] = [:]
    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let client: ProviderClient
    @ObservationIgnored private let fileURL: URL?

    init(secrets: SecretStore, client: ProviderClient = ProviderClient(), fileURL: URL?) {
        self.secrets = secrets
        self.client = client
        self.fileURL = fileURL
        config = ProviderConfig.load(from: fileURL)
    }

    // MARK: Rows

    var entries: [ProviderEntry] {
        ProviderCatalog.builtIns.map { p in
            ProviderEntry(id: p.id, name: p.name, mark: p.mark, logo: p.logo, isCustom: false, apiProtocol: p.apiProtocol,
                          hosts: p.hosts, commonModels: p.commonModels, catalogModels: p.catalogModels, keyCheckPath: p.keyCheckPath,
                          notFoundMeansAuthorized: p.notFoundMeansAuthorized, access: p.access, tag: p.tag)
        } + config.custom.map { c in
            ProviderEntry(id: c.id, name: c.name, mark: Self.mark(for: c.name), logo: nil, isCustom: true,
                          apiProtocol: c.apiProtocol, hosts: [ProviderHost(label: "", baseURL: c.baseURL)], commonModels: [])
        }
    }

    func entry(_ id: String) -> ProviderEntry? { entries.first { $0.id == id } }

    func hasKey(_ id: String) -> Bool { config.withKey.contains(id) }

    func status(of id: String) -> ProviderStatus {
        statuses[id] ?? (hasKey(id) ? .configured : .unconfigured)
    }

    var connectedCount: Int { entries.filter { status(of: $0.id).isConnected }.count }

    // MARK: Keys

    /// Reads the Keychain at most once per run per provider (S12).
    func savedKey(_ id: String) -> String? {
        if let key = keyCache[id] { return key }
        guard hasKey(id), let key = try? secrets.read(id), !key.isEmpty else { return nil }
        keyCache[id] = key
        // 10a: a key Formora keeps never reaches a model (Y2).
        SecretShield.shared.register(key)
        return key
    }

    func saveKey(_ raw: String, for id: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        SecretShield.shared.register(key)
        guard !key.isEmpty else { throw ProviderFormProblem.keyRequired }
        try secrets.write(key, for: id)
        keyCache[id] = key
        config.withKey.insert(id)
        config.chosenHosts[id] = nil // a new key finds its host again
        // A new key may be a new plan: the levels its host refused start over.
        config.rejectedReasoning = config.rejectedReasoning.filter { !$0.hasPrefix(id + "/") }
        forgetRuntimeState(id)
        persist()
    }

    func clearKey(_ id: String) throws {
        let users = usage(id)
        guard users == 0 else { throw ProviderFormProblem.inUse(users) }
        try secrets.delete(id)
        keyCache[id] = nil
        config.withKey.remove(id)
        config.chosenHosts[id] = nil
        forgetRuntimeState(id)
        persist()
    }

    // MARK: Tool calls (7d, D8)

    func toolMode(_ id: String) -> ToolCallMode { config.toolModes[id] ?? .auto }

    /// A deliberate change in the dialog also forgets which models 自动 moved to text, so they try native again.
    func setToolMode(_ mode: ToolCallMode, for id: String) throws {
        guard mode != toolMode(id) else { return }
        config.toolModes[id] = mode == .auto ? nil : mode
        config.textToolModels = config.textToolModels.filter { !$0.hasPrefix(id + "/") }
        persist()
    }

    func usesTextTools(providerID: String, modelID: String) -> Bool {
        switch toolMode(providerID) {
        case .text: true
        case .native: false
        case .auto: config.textToolModels.contains(providerID + "/" + modelID)
        }
    }

    /// 自动: this model refused native tools; from now on it gets them as text.
    func rememberTextTools(providerID: String, modelID: String) {
        guard config.textToolModels.insert(providerID + "/" + modelID).inserted else { return }
        persist()
    }

    /// The models of a provider that 自动 moved to text.
    func textToolModels(_ id: String) -> [String] {
        config.textToolModels.filter { $0.hasPrefix(id + "/") }.map { String($0.dropFirst(id.count + 1)) }.sorted()
    }

    // MARK: Reasoning levels (user 2026-09-18)

    /// The levels this model's host refused: left out of the menu, never sent again.
    func rejectedReasoning(providerID: String, modelID: String) -> Set<ReasoningLevel> {
        let prefix = providerID + "/" + modelID + "#"
        return Set(config.rejectedReasoning.filter { $0.hasPrefix(prefix) }.compactMap { ReasoningLevel(rawValue: String($0.dropFirst(prefix.count))) })
    }

    /// The host refused a request with this level: remembered, so the same model isn't asked it again.
    func rememberRejectedReasoning(providerID: String, modelID: String, level: ReasoningLevel) {
        guard config.rejectedReasoning.insert(providerID + "/" + modelID + "#" + level.rawValue).inserted else { return }
        persist()
    }

    // MARK: Custom providers

    /// Checked in the mockup's order: key, name, duplicate name, URL. Editing may leave the key empty to keep it.
    func problem(with draft: CustomProviderDraft, editing id: String?) -> ProviderFormProblem? {
        let keepsKey = id.map(hasKey) ?? false
        if draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !keepsKey { return .keyRequired }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .nameRequired }
        let normalized = FileSearch.normalize(name)
        if entries.contains(where: { $0.id != id && FileSearch.normalize($0.name) == normalized }) { return .nameTaken }
        if !Self.isValidBaseURL(draft.baseURL) { return .badURL }
        return nil
    }

    /// Adds or edits. Changing the URL or protocol drops the provider's test result and model list (S17).
    @discardableResult
    /// The base as Formora needs it: without a trailing slash, and without the endpoint's own tail when the whole
    /// address was pasted (user 2026-09-16: Command Code's docs give `…/provider/v1/chat/completions`; with the tail kept
    /// the request went to `…/chat/completions/chat/completions`, a 404). Anthropic's `/v1/messages` is added whole, so
    /// its `/v1` goes too.
    nonisolated static func normalizedBaseURL(_ raw: String, apiProtocol: APIProtocol) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func drop(_ suffix: String) {
            while url.hasSuffix("/") { url.removeLast() }
            if url.lowercased().hasSuffix(suffix.lowercased()) { url = String(url.dropLast(suffix.count)) }
        }
        switch apiProtocol {
        case .openAICompletions: drop("/chat/completions")
        case .openAIResponses: drop("/responses")
        case .anthropicMessages:
            drop("/messages")
            drop("/v1")
        case .googleGenerativeAI: drop("/models")
        }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    func saveCustom(_ draft: CustomProviderDraft, editing id: String?) throws -> String {
        if let problem = problem(with: draft, editing: id) { throw problem }
        let url = Self.normalizedBaseURL(draft.baseURL, apiProtocol: draft.apiProtocol)
        let providerID = id ?? "custom-\(UUID().uuidString.prefix(8).lowercased())"
        let provider = CustomProvider(id: providerID, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                      baseURL: url, apiProtocol: draft.apiProtocol)
        if let index = config.custom.firstIndex(where: { $0.id == providerID }) {
            let old = config.custom[index]
            config.custom[index] = provider
            if old.baseURL != provider.baseURL || old.apiProtocol != provider.apiProtocol { forgetRuntimeState(providerID) }
        } else {
            config.custom.append(provider)
        }
        persist()
        if !draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try saveKey(draft.key, for: providerID) }
        return providerID
    }

    func deleteCustom(_ id: String) throws {
        guard config.custom.contains(where: { $0.id == id }) else { return }
        let users = usage(id)
        guard users == 0 else { throw ProviderFormProblem.inUse(users) }
        if hasKey(id) { try secrets.delete(id) }
        config.custom.removeAll { $0.id == id }
        config.withKey.remove(id)
        config.chosenHosts[id] = nil
        keyCache[id] = nil
        forgetRuntimeState(id)
        persist()
    }

    // MARK: ChatGPT sign-in (7i, U1–U2)

    /// The signed-in ChatGPT account, when there is one.
    func chatGPTCredential() -> ChatGPTCredential? {
        savedKey(ChatGPTAuth.providerID).flatMap { ChatGPTCredential.decode($0) }
    }

    func saveChatGPT(_ credential: ChatGPTCredential) throws {
        let id = ChatGPTAuth.providerID
        let text = credential.encoded()
        try secrets.write(text, for: id)
        keyCache[id] = text
        config.withKey.insert(id)
        persist()
        // The row's subtitle already says who is signed in.
        statuses[id] = .connected(note: nil)
        modelLists[id] = .loaded(entry(id)?.catalogModels ?? [])
    }

    /// Like clearing a key: refused while Agents use it.
    func signOutChatGPT() throws {
        cancelSignIn(ChatGPTAuth.providerID)
        try clearKey(ChatGPTAuth.providerID)
    }

    func cancelSignIn(_ id: String) {
        signIns[id] = nil
        loopback?.stop()
        loopback = nil
    }

    /// The browser, back to localhost:1455; if that port is taken, the code on a web page.
    func signInChatGPT() async {
        let id = ChatGPTAuth.providerID
        switch signIns[id] {
        case .waiting, .deviceCode: return
        default: break
        }
        signIns[id] = .waiting
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        let listener = OAuthLoopback(port: ChatGPTAuth.callbackPort, path: ChatGPTAuth.callbackPath, redirectHost: "localhost")
        let redirect: URL
        do {
            redirect = try await listener.start()
        } catch {
            return await signInChatGPTWithCode()
        }
        loopback = listener
        openURL(ChatGPTAuth.authorizationURL(challenge: PKCE.challenge(for: verifier), state: state, redirect: redirect))
        let callback = await listener.waitForCallback()
        loopback = nil
        guard signIns[id] == .waiting else { return }
        switch callback {
        case let .success(code, returned):
            guard returned == state else {
                signIns[id] = .failed("登录回跳对不上，请重新登录")
                return
            }
            do {
                try saveChatGPT(try await ChatGPTAuth.exchange(code: code, verifier: verifier, redirect: redirect.absoluteString,
                                                               transport: client.transport))
                signIns[id] = nil
            } catch {
                signIns[id] = .failed(ChatGPTAuth.message(error))
            }
        case .denied(let reason):
            signIns[id] = .failed(reason)
        case .invalid:
            signIns[id] = .failed("登录没有完成")
        }
    }

    func signInChatGPTWithCode() async {
        let id = ChatGPTAuth.providerID
        do {
            let device = try await ChatGPTAuth.requestDeviceCode(transport: client.transport)
            signIns[id] = .deviceCode(device.userCode)
            openURL(ChatGPTAuth.deviceURL)
            let credential = try await ChatGPTAuth.waitForDevice(device, transport: client.transport) { [weak self] in
                if case .deviceCode = self?.signIns[id] { return true }
                return false
            }
            guard let credential else { return }
            try saveChatGPT(credential)
            signIns[id] = nil
        } catch {
            if signIns[id] != nil { signIns[id] = .failed(ChatGPTAuth.message(error)) }
        }
    }

    /// What a request authenticates with (U2): the key — or a ChatGPT token fresh enough for the next request, with
    /// its account header. A refresh that fails says so on the row.
    func authorization(_ id: String) async -> (key: String, headers: [String: String])? {
        guard entry(id)?.access == .chatGPT else { return savedKey(id).map { ($0, [:]) } }
        guard var credential = chatGPTCredential() else { return nil }
        if credential.needsRefresh() {
            do {
                credential = try await ChatGPTAuth.refresh(credential, transport: client.transport)
                try saveChatGPT(credential)
            } catch {
                statuses[id] = .failed("登录已过期，重新登录 ChatGPT")
                return nil
            }
        }
        return (credential.access, [ChatGPTAuth.accountHeader: credential.accountID])
    }

    private func testChatGPT() async {
        let id = ChatGPTAuth.providerID
        guard chatGPTCredential() != nil else {
            statuses[id] = nil
            return
        }
        guard await authorization(id) != nil else { return }
        statuses[id] = .connected(note: nil)
    }

    // MARK: Connection test and model list

    /// The provider's hosts, the one that last accepted its key first.
    func endpoints(for id: String) -> [ProviderEndpoint] {
        guard let entry = entry(id) else { return [] }
        var hosts = entry.hosts.map(\.baseURL)
        if id == ChatGPTAuth.providerID, let base = chatGPTBase { hosts = [base] }
        if let chosen = config.chosenHosts[id], let index = hosts.firstIndex(of: chosen) {
            hosts.insert(hosts.remove(at: index), at: 0)
        }
        // A base saved with the endpoint's tail before 1.0.7 works without being saved again (user 2026-09-16).
        return hosts.map {
            ProviderEndpoint(baseURL: Self.normalizedBaseURL($0, apiProtocol: entry.apiProtocol), apiProtocol: entry.apiProtocol,
                             keyCheckPath: entry.keyCheckPath, notFoundMeansAuthorized: entry.notFoundMeansAuthorized)
        }
    }

    /// Where a request for `model` goes: the provider's first host, speaking the protocol the model is served on
    /// (`ProviderEndpoint.serving`). Only a platform the user added can be mixed; its list is read here when it hasn't
    /// been this run — once, not per request.
    func endpoint(for id: String, model: String) async -> ProviderEndpoint? {
        guard entry(id)?.isCustom == true, modelLists[id] == nil else { return knownEndpoint(for: id, model: model) }
        await loadModels(id)
        return knownEndpoint(for: id, model: model)
    }

    /// The same from what is already known — for the menu, which can't wait for a list.
    func knownEndpoint(for id: String, model: String) -> ProviderEndpoint? {
        guard let endpoint = endpoints(for: id).first else { return nil }
        guard entry(id)?.isCustom == true, case .loaded(let models) = modelLists[id] else { return endpoint }
        return endpoint.serving(models.first { $0.id == model })
    }

    /// Tests the saved key; on failure tries the provider's other host and remembers the one that works (S15).
    func test(_ id: String) async {
        if entry(id)?.access == .chatGPT { return await testChatGPT() }
        guard let key = savedKey(id) else {
            statuses[id] = nil
            return
        }
        statuses[id] = .testing
        let (outcome, host) = await Self.firstAccepting(endpoints(for: id), key: key, client: client)
        guard hasKey(id) else { return } // cleared while testing
        if let host, (entry(id)?.hosts.count ?? 0) > 1, config.chosenHosts[id] != host {
            config.chosenHosts[id] = host
            persist()
        }
        statuses[id] = ProviderStatus(outcome)
    }

    /// The editor's 测试连接, before anything is saved.
    func testUnsaved(key: String, endpoints: [ProviderEndpoint]) async -> ConnectionOutcome {
        await Self.firstAccepting(endpoints, key: key.trimmingCharacters(in: .whitespacesAndNewlines), client: client).0
    }

    /// The row's count (user 2026-09-11): 「x」 until the provider's real list has been read, then the real number.
    func modelCountLabel(_ id: String) -> String {
        switch modelLists[id] {
        case .loaded(let models): "\(models.count) 个可用模型"
        case .loading: "正在读取模型…"
        default: "x 个可用模型"
        }
    }

    /// Opening 模型 reads the real list of every provider with a key that hasn't been read this run.
    /// Providers without a key are never contacted.
    func loadAllConfigured() async {
        let ids = entries.map(\.id).filter { hasKey($0) && modelLists[$0] == nil }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.loadModels(id) } }
        }
    }

    /// Fetched once per run unless `refresh` (S11); tests the key first when it hasn't connected yet.
    func loadModels(_ id: String, refresh: Bool = false) async {
        // The ChatGPT backend's list is version-gated: the catalog's models instead (7i, U3).
        if entry(id)?.access == .chatGPT {
            modelLists[id] = hasKey(id) ? .loaded(entry(id)?.catalogModels ?? []) : nil
            return
        }
        if !refresh, case .loaded = modelLists[id] { return }
        if !refresh, modelLists[id] == .loading { return }
        guard savedKey(id) != nil else { return }
        modelLists[id] = .loading
        if !status(of: id).isConnected { await test(id) }
        guard let key = savedKey(id), let endpoint = endpoints(for: id).first else {
            modelLists[id] = nil
            return
        }
        guard status(of: id).isConnected else {
            modelLists[id] = .failed(status(of: id).detail ?? status(of: id).label)
            return
        }
        let result = await client.models(endpoint, key: key)
        guard hasKey(id) else { return }
        // 目录 ∪ 实时 (user 2026-09-18): the catalog's rows first; a host without a list has the catalog as its list.
        let catalog = entry(id)?.catalogModels ?? []
        switch result {
        case .models(let models): modelLists[id] = .loaded(Self.merge(catalog: catalog, live: models))
        case .unsupported:
            modelLists[id] = catalog.isEmpty ? .unsupported : .loaded(catalog)
            catalogOnly.insert(id)
        case .failed(let outcome):
            let status = ProviderStatus(outcome)
            modelLists[id] = .failed(status.detail ?? status.label)
        }
    }

    /// What is known about a model: the list's entry, every gap filled from omp's catalog — a custom platform's model by
    /// its host, then by its bare id (user 2026-09-18).
    func modelInfo(_ providerID: String?, _ modelID: String) -> ModelInfo? {
        guard let providerID, !modelID.isEmpty else { return nil }
        let catalog = ModelCatalog.model(providerID: providerID, modelID: modelID, baseURL: entry(providerID)?.baseURL).map(ModelInfo.from)
            ?? entry(providerID)?.catalogModels.first { $0.id == modelID }
        var listed: ModelInfo?
        if case .loaded(let models) = modelLists[providerID] { listed = models.first { $0.id == modelID } }
        guard var info = listed ?? catalog else { return nil }
        info.name = info.name ?? catalog?.name
        info.contextWindow = info.contextWindow ?? catalog?.contextWindow
        info.maxOutput = info.maxOutput ?? catalog?.maxOutput
        info.acceptsImages = info.acceptsImages ?? catalog?.acceptsImages
        info.cost = info.cost ?? catalog?.cost
        info.reasoning = info.reasoning ?? catalog?.reasoning
        return info
    }

    /// 目录 ∪ 实时 (user 2026-09-18): the catalog's rows in its order with their data — a gap filled from the live list,
    /// the live list's endpoints kept — then what only the live list has, in its order.
    nonisolated static func merge(catalog: [ModelInfo], live: [ModelInfo]) -> [ModelInfo] {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(catalog.map(\.id))
        let rows = catalog.map { row -> ModelInfo in
            guard let listed = liveByID[row.id] else { return row }
            var merged = row
            merged.name = row.name ?? listed.name
            merged.contextWindow = row.contextWindow ?? listed.contextWindow
            merged.maxOutput = row.maxOutput ?? listed.maxOutput
            merged.acceptsImages = row.acceptsImages ?? listed.acceptsImages
            merged.endpoints = listed.endpoints
            return merged
        }
        return rows + live.filter { !known.contains($0.id) }
    }

    /// Whether a model is known to see images (7j, V2) — unknown counts as no.
    func seesImages(_ providerID: String?, _ modelID: String) -> Bool {
        modelInfo(providerID, modelID)?.acceptsImages == true
    }

    /// 测试连接 for an Agent's model (phase 5a, A7): the key works *and* the model is in the provider's real
    /// list. A real generation test needs the agent core's request layer (phase 7).
    func testModel(providerID: String, modelID: String) async -> ConnectionOutcome {
        guard hasKey(providerID) else { return .invalidKey("服务商未配置") }
        await loadModels(providerID)
        switch status(of: providerID) {
        case .connected: break
        case .invalid(let message): return .invalidKey(message)
        case .timedOut: return .timedOut
        case .failed(let message): return .failed(message)
        case .unconfigured, .configured, .testing: return .failed("没能完成连接测试")
        }
        switch modelLists[providerID] {
        case .loaded(let models) where catalogOnly.contains(providerID):
            return .connected(note: models.contains { $0.id == modelID } ? "这家服务商不提供模型列表，这个 Model ID 在 omp 的目录里"
                                                                    : "这家服务商不提供模型列表，没法核对 Model ID")
        case .loaded(let models):
            if models.contains(where: { $0.id == modelID }) { return .connected(note: nil) }
            return .failed("\(entry(providerID)?.name ?? providerID) 的模型列表里没有「\(modelID)」")
        case .unsupported:
            return .connected(note: "这家服务商不提供模型列表，没法核对 Model ID")
        case .failed(let message):
            return .failed(message)
        case .loading, nil:
            return .connected(note: nil)
        }
    }

    nonisolated static func firstAccepting(_ endpoints: [ProviderEndpoint], key: String,
                                           client: ProviderClient) async -> (ConnectionOutcome, String?) {
        var first: ConnectionOutcome?
        for endpoint in endpoints {
            let outcome = await client.check(endpoint, key: key)
            if outcome.isConnected { return (outcome, endpoint.baseURL) }
            if first == nil { first = outcome }
        }
        return (first ?? .failed("没有可用的地址"), nil)
    }

    // MARK: Helpers

    /// S13: 「sk-…••••1234」. Short keys are fully hidden.
    nonisolated static func mask(_ key: String) -> String {
        guard key.count > 10 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(3))…••••\(key.suffix(4))"
    }

    nonisolated static func isValidBaseURL(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: #"^https?://[^\s]+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let url = URL(string: text), let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Custom providers show their first two letters (old app: 「新增的保留现在逻辑」).
    nonisolated static func mark(for name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
    }

    private func forgetRuntimeState(_ id: String) {
        statuses[id] = nil
        modelLists[id] = nil
        catalogOnly.remove(id)
    }

    private func persist() {
        try? config.save(to: fileURL)
    }
}
