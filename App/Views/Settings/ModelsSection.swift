import SwiftUI

/// 设置 → 模型: the providers list (design spec §4.1 `.provider-row`, §7.4).
struct ModelsSection: View {
    let state: AppState

    private var providers: ProviderStore { state.providers }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .models,
                                note: "\(providers.entries.count) 个服务商 · \(providers.connectedCount) 个已连接") {
                Button("添加自定义服务商") { state.providerEditor = .newCustom }
                    .buttonStyle(FormoraButtonStyle())
                    .accessibilityIdentifier("models.addCustom")
            }
            // Two kinds (user 2026-09-12): a key paid by use, or a plan you already pay for.
            ProviderGroup(title: "API 绑定", note: "填服务商的 API Key，按用量付费", identifier: "models.list",
                          entries: providers.entries.filter { $0.access == .key }, state: state)
            ProviderGroup(title: "订阅绑定", note: "用已经买了的订阅，在浏览器里登录账号，不用 API Key",
                          identifier: "models.subscriptions",
                          entries: providers.entries.filter { $0.access != .key }, state: state)
                .padding(.top, 26)
        }
        .task { await providers.loadAllConfigured() }
    }
}

/// One kind of provider, under its title (7i, D57).
private struct ProviderGroup: View {
    let title: String
    let note: String
    let identifier: String
    let entries: [ProviderEntry]
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(FormoraFont.ui(13, weight: 600)).foregroundStyle(Palette.ink.color)
                Text(note).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).lineLimit(1)
            }
            .padding(.bottom, 8)
            // `.provider-list`: the top rule belongs to the container.
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    ProviderRow(entry: entry, state: state)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }
}

private struct ProviderRow: View {
    let entry: ProviderEntry
    let state: AppState

    private var providers: ProviderStore { state.providers }
    private var status: ProviderStatus { providers.status(of: entry.id) }
    private var isOpen: Bool { state.openModelLists.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ProviderMark(entry: entry)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(FormoraFont.ui(12.5, weight: 600))
                            .foregroundStyle(Palette.ink.color)
                        if let tag = entry.tag { ProviderTag(text: tag) }
                    }
                    Text(subtitle)
                        .font(FormoraFont.mono(10))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = status.detail {
                        Text(detail)
                            .font(FormoraFont.ui(11))
                            .foregroundStyle(status.isConnected ? Palette.inkFaint.color : Palette.alert.color)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                            .accessibilityIdentifier("models.detail.\(entry.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProviderStatusLine(status: status)
                    .accessibilityIdentifier("models.status.\(entry.id)")
                HStack(spacing: 8) {
                    if providers.hasKey(entry.id) {
                        Button(isOpen ? "收起模型" : "查看模型") { toggleModels() }
                            .buttonStyle(FormoraButtonStyle())
                            .accessibilityIdentifier("models.list.\(entry.id)")
                    }
                    if entry.access == .chatGPT {
                        ChatGPTButtons(state: state)
                    } else {
                        Button(providers.hasKey(entry.id) ? "重新配置" : "配置") {
                            state.providerEditor = .provider(entry.id)
                        }
                        .buttonStyle(FormoraButtonStyle())
                        .accessibilityIdentifier("models.configure.\(entry.id)")
                    }
                }
            }
            .padding(.vertical, 13)

            if entry.access == .chatGPT, let progress = providers.signIns[entry.id] {
                ChatGPTSignInPanel(state: state, progress: progress)
                    .padding(.leading, 47)
                    .padding(.bottom, 12)
            }
            // A key cleared while the list was open left it spinning (user 2026-09-14): no key, no list.
            if isOpen, providers.hasKey(entry.id) {
                ModelListPanel(entry: entry, providers: providers)
                    .padding(.leading, 47) // = 36 + 11: aligned to the name, like `.mcp-row` config
                    .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.row.\(entry.id)")
    }

    /// 「x 个可用模型」 until the real list is read, then the real count (user 2026-09-11); custom providers add
    /// 「protocol · base URL」, two-region providers the region that accepted the key.
    private var subtitle: String {
        // 7i: who is signed in, or what signing in gives.
        if entry.access == .chatGPT {
            return providers.chatGPTCredential()?.summary ?? "用 ChatGPT Plus / Pro 的订阅额度，不用 API Key"
        }
        var parts = [providers.modelCountLabel(entry.id)]
        if entry.isCustom {
            parts.append("\(entry.apiProtocol.rawValue) · \(entry.baseURL)")
        } else if entry.hosts.count > 1, let chosen = providers.config.chosenHosts[entry.id],
                  let host = entry.hosts.first(where: { $0.baseURL == chosen }) {
            parts.append(host.label)
        }
        return parts.joined(separator: " · ")
    }

    private func toggleModels() {
        if isOpen {
            state.openModelLists.remove(entry.id)
        } else {
            state.openModelLists.insert(entry.id)
            Task { await providers.loadModels(entry.id) }
        }
    }
}

/// `.capability-mark`: 32pt tile with the provider's official logo (single colour), or its letters.
struct ProviderMark: View {
    let entry: ProviderEntry

    var body: some View {
        Group {
            if let name = entry.logo, let icon = ProviderLogos.icon(name) {
                IconView(icon, size: 16)
            } else {
                Text(entry.mark).font(FormoraFont.mono(10, weight: 700))
            }
        }
        .foregroundStyle(Palette.inkMuted.color)
        .frame(width: 32, height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
        .frame(width: 36, alignment: .leading)
    }
}

/// `.status-line` with the mockup's per-status colours: connected green, errors alert, configured ink.
struct ProviderStatusLine: View {
    let status: ProviderStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(status.label).font(FormoraFont.ui(10.5)).foregroundStyle(text)
        }
        .fixedSize()
    }

    private var text: Color {
        switch status {
        case .connected: Palette.success.color
        case .invalid, .failed, .timedOut: Palette.alert.color
        case .configured: Palette.ink.color
        case .testing: Palette.accent.color
        case .unconfigured: Palette.inkMuted.color
        }
    }

    private var dot: Color {
        switch status {
        case .configured: Palette.inkMuted.color
        case .unconfigured: Palette.inkFaint.color
        default: text
        }
    }
}

/// The provider's real model list, fetched on demand (S11): filter above 12 models, capped at 240pt.
private struct ModelListPanel: View {
    let entry: ProviderEntry
    let providers: ProviderStore

    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch providers.modelLists[entry.id] {
            case .loading, nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在获取模型列表…").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
                }
                .accessibilityIdentifier("models.loading.\(entry.id)")
            case .failed(let message):
                HStack(spacing: 10) {
                    Text(message).font(FormoraFont.ui(11.5)).foregroundStyle(Palette.alert.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await providers.loadModels(entry.id, refresh: true) } }
                        .buttonStyle(FormoraButtonStyle())
                }
            case .unsupported:
                Text("这家服务商不提供模型列表。下面是常用模型，也可以在 Agent 里直接填写 Model ID。")
                    .font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
                list(entry.commonModels)
            case .loaded(let models):
                header(count: models.count)
                if models.count > 12 {
                    SearchField(placeholder: "过滤模型", text: $filter, identifier: "models.filter.\(entry.id)")
                        .frame(maxWidth: 320)
                }
                list(filtered(models))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.panel.\(entry.id)")
    }

    /// The count is already on the row's second line; here only where the list comes from and a refresh.
    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(entry.name) 返回的模型").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
            IconActionButton(icon: Icons.refresh, label: "刷新模型列表", identifier: "models.refresh.\(entry.id)") {
                Task { await providers.loadModels(entry.id, refresh: true) }
            }
        }
    }

    /// The same matching as the file tree's search: case and full-width folded.
    private func filtered(_ models: [ModelInfo]) -> [ModelInfo] {
        let query = FileSearch.normalize(filter)
        guard !query.isEmpty else { return models }
        return models.filter { FileSearch.normalize($0.id + " " + ($0.name ?? "")).contains(query) }
    }

    @ViewBuilder private func list(_ models: [ModelInfo]) -> some View {
        if models.isEmpty {
            Text(filter.isEmpty ? "这家服务商没有返回任何模型" : "没有匹配的模型")
                .font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(models) { model in ModelLine(model: model) }
                }
            }
            .frame(maxHeight: min(CGFloat(models.count) * 30, 240))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        }
    }
}

private struct ModelLine: View {
    let model: ModelInfo

    var body: some View {
        HStack(spacing: 10) {
            Text(model.id)
                .font(FormoraFont.mono(11.5))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let name = model.name, name != model.id {
                Text(name).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let context = model.contextWindow {
                Text("\(Self.tokens(context)) 上下文").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
            }
            if model.acceptsImages == true {
                Text("识图")
                    .font(FormoraFont.mono(10))
                    .foregroundStyle(Palette.inkMuted.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Palette.surfaceRaised2.color))
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 12)
    }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(Int((Double(count) / 1_000_000).rounded()))M" }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))K" }
        return "\(count)"
    }
}
