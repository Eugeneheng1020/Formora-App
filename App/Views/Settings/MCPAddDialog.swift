import SwiftUI

/// Adding an MCP server in three layers (spec §8.4) — 推荐 (one click, only what the user must supply),
/// 粘贴配置 (the JSON from a service's docs), 手动填写 (which also edits an existing server). The scrim
/// doesn't close it; Esc and ✕ do.
struct MCPAddDialog: View {
    let state: AppState
    let dialog: AppState.MCPDialog

    @State private var mode: AppState.MCPAddMode = .catalog
    @State private var entry: MCPCatalogEntry?
    @State private var name = ""
    @State private var token = ""
    @State private var paste = ""
    @State private var manual = ManualForm()
    @State private var problem: String?

    private var store: MCPStore { state.mcp }
    private var editingID: String? { if case .edit(let id) = dialog { id } else { nil } }

    var body: some View {
        ZStack {
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.line.color).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if editingID == nil, entry == nil {
                            SegmentedControl(options: AppState.MCPAddMode.allCases.map { ($0, $0.title) }, selection: $mode,
                                             identifier: "mcpAdd.mode")
                                .fixedSize()
                                .padding(.bottom, 14)
                        }
                        content
                        if let problem { InlineError(text: problem, identifier: "mcpAdd.problem").padding(.top, 8) }
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 470)
                .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Palette.line.color).frame(height: 1)
                footer
            }
            .frame(width: 620)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .modalShadow()
            .background {
                Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mcpAdd")
        }
        .onAppear(perform: load)
        .onChange(of: mode) { problem = nil }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("MCP SERVICE").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
                Text(title).font(FormoraFont.ui(18, weight: 700)).foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("mcpAdd.title")
                Text(subtitle).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color)
            }
            Spacer(minLength: 0)
            IconActionButton(icon: Icons.close, label: "关闭", identifier: "mcpAdd.close", action: close)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var title: String {
        if let id = editingID { return "配置 \(store.server(id)?.name ?? "")" }
        if let entry { return "添加\(entry.name)" }
        return mode == .catalog ? "添加 MCP 服务" : mode.title
    }

    private var subtitle: String {
        if editingID != nil { return "连接信息全局保存；敏感请求头和环境变量写入 macOS 钥匙串。" }
        if let entry {
            return entry.field == nil && !entry.usesOAuth ? "这个服务不需要额外信息，直接添加即可。" : "只需要下面这些信息，其余连接参数已经配好。"
        }
        switch mode {
        case .catalog: return "从推荐里挑一个，或用另外两种方式接入。"
        case .paste: return "把服务文档里的配置整段复制过来，自动识别。"
        case .manual: return "连接信息全局保存；敏感请求头和环境变量写入 macOS 钥匙串。"
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(footnote).font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
            Spacer(minLength: 0)
            if entry != nil {
                Button("上一步") { entry = nil; problem = nil }.buttonStyle(FormoraButtonStyle(kind: .ghost))
            } else {
                Button("取消", action: close).buttonStyle(FormoraButtonStyle(kind: .ghost))
            }
            if entry != nil || mode != .catalog || editingID != nil {
                Button(editingID == nil ? "添加" : "保存") { save() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .paste && entry == nil && editingID == nil && parsed == nil)
                    .accessibilityIdentifier("mcpAdd.save")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
    }

    private var footnote: String {
        if editingID != nil || mode == .manual || mode == .paste { return "敏感值由 macOS 钥匙串保管" }
        return entry == nil ? "目录里没有的服务，用「粘贴配置」或「手动填写」" : "添加后可在列表里测试连接"
    }

    // MARK: Layers

    @ViewBuilder private var content: some View {
        if editingID != nil {
            manualForm
        } else if let entry {
            entryForm(entry)
        } else {
            switch mode {
            case .catalog: catalog
            case .paste: pasteForm
            case .manual: manualForm
            }
        }
    }

    /// Layer 1. Transport and command never show — only name, summary and how it signs in.
    private var catalog: some View {
        VStack(spacing: 0) {
            ForEach(MCPCatalogEntry.all) { item in
                let added = store.servers.contains { $0.catalogID == item.id }
                HStack(spacing: 11) {
                    CapabilityMark(text: item.mark)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                        Text(item.summary).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color).padding(.top, 2)
                        HStack(spacing: 6) {
                            if item.usesOAuth { SmallTag(text: "浏览器登录") }
                            if item.field != nil { SmallTag(text: item.tokenIsRequired ? "需要令牌" : "可用令牌") }
                            if item.isStdio, !MCPBuild.supportsStdio { SmallTag(text: "只有官网版能用") }
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if added {
                        SmallTag(text: "已添加")
                    } else {
                        Button("添加") { choose(item) }
                            .buttonStyle(FormoraButtonStyle())
                            .accessibilityIdentifier("mcpAdd.catalog.\(item.id)")
                    }
                }
                .padding(.vertical, 13)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }

    private func entryForm(_ item: MCPCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            field("显示名称") { InputField(placeholder: item.name, text: $name, identifier: "mcpAdd.name") }
            if let token = item.field {
                field(token.label) {
                    VStack(alignment: .leading, spacing: 5) {
                        SecretInput(placeholder: token.placeholder, text: $token, identifier: "mcpAdd.token")
                        Text(token.hint).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let note = item.note {
                Text(note).font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkMuted.color).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Layer 2: shows only what was recognised (transport, endpoint, counts), not a field-by-field form.
    private var pasteForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            field("配置内容") {
                FormoraTextEditor(placeholder: "{\n  \"mcpServers\": {\n    \"名字\": { \"url\": \"https://…\" }\n  }\n}",
                                  text: $paste, height: 180, metrics: .detail, identifier: "mcpAdd.paste")
            }
            if !paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch MCPConfigParser.parse(paste) {
                case .success(let result):
                    VStack(alignment: .leading, spacing: 7) {
                        Text("识别成功").font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.success.color)
                        HStack(spacing: 6) {
                            SmallTag(text: result.transport.isStdioCase ? "stdio" : "Streamable HTTP")
                            SmallTag(text: result.endpoint)
                            let secrets = result.secretHeaders.count + result.secretEnvironment.count
                            if secrets > 0 { SmallTag(text: "\(secrets) 项密钥") }
                        }
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surfaceRaised.color))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                    field("显示名称") { InputField(placeholder: result.name.isEmpty ? "给它起个名字" : result.name, text: $name, identifier: "mcpAdd.name") }
                case .failure(let error):
                    InlineError(text: error.message, identifier: "mcpAdd.parseProblem")
                }
            }
        }
    }

    /// Layer 3, also the editor for an existing server.
    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            field("名称") { InputField(placeholder: "名称", text: $manual.name, identifier: "mcpAdd.manualName") }
            field("传输方式") {
                SegmentedControl(options: [(true, "Streamable HTTP"), (false, "stdio")], selection: $manual.isHTTP,
                                 identifier: "mcpAdd.transport")
                    .fixedSize()
            }
            if manual.isHTTP {
                field("URL") { InputField(placeholder: "https://", text: $manual.endpoint, mono: true, identifier: "mcpAdd.url") }
                field("请求头（每行一个，如 X-Team: core）") {
                    FormoraTextEditor(placeholder: "Name: value", text: $manual.plain, height: 70, metrics: .detail, identifier: "mcpAdd.headers")
                }
                field("敏感请求头（写入钥匙串）") {
                    FormoraTextEditor(placeholder: secretPlaceholder("Authorization: Bearer …"), text: $manual.secret, height: 70,
                                      metrics: .detail, identifier: "mcpAdd.secretHeaders")
                }
            } else {
                field("命令") { InputField(placeholder: "npx", text: $manual.endpoint, mono: true, identifier: "mcpAdd.command") }
                field("参数（每行一个）") {
                    FormoraTextEditor(placeholder: "-y\n@scope/server", text: $manual.arguments, height: 70, metrics: .detail, identifier: "mcpAdd.args")
                }
                field("环境变量（写入钥匙串，每行 KEY=value）") {
                    FormoraTextEditor(placeholder: secretPlaceholder("KEY=value"), text: $manual.secret, height: 70, metrics: .detail,
                                      identifier: "mcpAdd.env")
                }
                if !MCPBuild.supportsStdio {
                    Text("stdio 服务要在本机启动进程，这个版本保存后不能连接，只有官网版能用。")
                        .font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
                }
            }
        }
    }

    private func secretPlaceholder(_ example: String) -> String {
        guard let id = editingID, let server = store.server(id), !server.secretNames.isEmpty else { return example }
        return "已保存 \(server.secretNames.count) 项（\(server.secretNames.joined(separator: "、"))），留空则保留"
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color)
            content()
        }
    }

    // MARK: Actions

    private var parsed: ParsedMCPServer? { try? MCPConfigParser.parse(paste).get() }

    private func load() {
        if case .add(let initial) = dialog { mode = initial }
        guard let id = editingID, let server = store.server(id) else { return }
        manual = ManualForm(server: server)
    }

    /// A catalog entry with nothing to ask is added straight away (spec §8.4).
    private func choose(_ item: MCPCatalogEntry) {
        problem = nil
        name = item.name
        token = ""
        if item.field == nil, item.note == nil {
            add(item.config(name: item.name, token: ""))
        } else {
            entry = item
        }
    }

    private func save() {
        problem = nil
        if let id = editingID {
            do {
                let form = try manual.parts()
                try store.update(id, name: manual.name, transport: form.transport, plainHeaders: form.plainHeaders,
                                 plainEnvironment: [:], secretValues: form.secrets.isEmpty ? nil : form.secrets)
                state.mcpDialog = nil
                state.toasts.show("MCP 服务已保存", note: "连接信息变了的话，记得重新测试连接")
            } catch {
                problem = (error as? MCPProblem)?.message ?? (error as? ManualForm.Problem)?.message ?? error.localizedDescription
            }
            return
        }
        if let entry {
            if entry.tokenIsRequired, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problem = "请先填写「\(entry.field?.label ?? "令牌")」"
                return
            }
            add(entry.config(name: name, token: token))
            return
        }
        switch mode {
        case .catalog:
            break
        case .paste:
            guard let parsed else { return }
            add(parsed.config(name: name))
        case .manual:
            do {
                let form = try manual.parts()
                var server = MCPServerConfig(id: MCPServerConfig.newID(), name: manual.name, transport: form.transport,
                                             plainHeaders: form.plainHeaders)
                if let header = form.secrets.keys.sorted().first, manual.isHTTP { server.auth = .header(name: header) }
                add((server, form.secrets))
            } catch {
                problem = (error as? ManualForm.Problem)?.message ?? error.localizedDescription
            }
        }
    }

    private func add(_ config: (server: MCPServerConfig, secrets: [String: String])) {
        do {
            try store.add(config.server, secrets: config.secrets)
            state.mcpDialog = nil
            let count = config.secrets.count
            state.toasts.show("已添加", note: "\(count > 0 ? "\(count) 项密钥已存入钥匙串；" : "")可以在列表里测试连接，然后在各 Agent 的 MCP 标签里启用")
        } catch {
            problem = (error as? MCPProblem)?.message ?? error.localizedDescription
        }
    }

    private func close() {
        state.mcpDialog = nil
    }
}

/// The manual form's text, turned into a transport, plain headers and secrets.
struct ManualForm: Equatable {
    enum Problem: Error { case badLine(String)
        var message: String { if case .badLine(let line) = self { "这一行看不懂：\(line)" } else { "" } }
    }

    var name = ""
    var isHTTP = true
    var endpoint = ""
    var arguments = ""
    var plain = ""
    var secret = ""

    init() {}

    init(server: MCPServerConfig) {
        name = server.name
        switch server.transport {
        case .http(let url):
            isHTTP = true
            endpoint = url
        case .stdio(let command, let args):
            isHTTP = false
            endpoint = command
            arguments = args.joined(separator: "\n")
        }
        plain = server.plainHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    func parts() throws -> (transport: MCPServerConfig.Transport, plainHeaders: [String: String], secrets: [String: String]) {
        let transport: MCPServerConfig.Transport = isHTTP
            ? .http(url: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            : .stdio(command: endpoint.trimmingCharacters(in: .whitespaces),
                     args: arguments.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return (transport, try Self.pairs(isHTTP ? plain : "", separator: ":"), try Self.pairs(secret, separator: isHTTP ? ":" : "="))
    }

    static func pairs(_ text: String, separator: Character) throws -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let index = line.firstIndex(of: separator) else { throw Problem.badLine(line) }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw Problem.badLine(line) }
            result[key] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}

/// A single-line secret field (`.detail-input` with secure entry).
struct SecretInput: View {
    let placeholder: String
    @Binding var text: String
    let identifier: String

    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField("", text: $text)
            .textFieldStyle(.plain)
            .font(FormoraFont.mono(12))
            .foregroundStyle(Palette.ink.color)
            .focused($isFocused)
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(FormoraFont.mono(12)).foregroundStyle(Palette.inkFaint.color).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier(identifier)
    }
}

extension MCPServerConfig.Transport {
    var isStdioCase: Bool { if case .stdio = self { true } else { false } }
}

extension ParsedMCPServer {
    /// For the 「识别成功」 box: the URL or the command line.
    var endpoint: String {
        switch transport {
        case .http(let url): url
        case .stdio(let command, let args): ([command] + args).joined(separator: " ")
        }
    }
}
