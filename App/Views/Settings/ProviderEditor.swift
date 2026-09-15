import SwiftUI

/// The provider dialog (mockup `openProviderEditor`): configure a built-in's key, or add / edit a custom
/// provider. The saved key shows masked in the empty field; the eye reveals it; typing replaces it; leaving
/// the field empty keeps it (S13). Clicking the scrim does not close it; Esc and ✕ do.
struct ProviderEditor: View {
    let state: AppState
    let target: AppState.ProviderEditorTarget

    private enum TestState: Equatable {
        case idle, testing
        case done(ConnectionOutcome)
    }

    @State private var draft = CustomProviderDraft()
    @State private var problem: ProviderFormProblem?
    @State private var savedKey: String?
    @State private var revealsKey = false
    @State private var test: TestState = .idle
    @State private var confirmingRemoval = false
    @State private var failure: String?
    /// 工具调用 (7d, D8), saved with the dialog.
    @State private var toolMode: ToolCallMode = .auto

    private var providers: ProviderStore { state.providers }
    private var providerID: String? {
        if case .provider(let id) = target { return id }
        return nil
    }
    private var entry: ProviderEntry? { providerID.flatMap(providers.entry) }
    private var isCustom: Bool { entry?.isCustom ?? true }
    private var title: String {
        guard let entry else { return "添加自定义服务商" }
        return entry.isCustom ? "编辑 \(entry.name)" : "配置 \(entry.name)"
    }

    var body: some View {
        ZStack {
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.line.color).frame(height: 1)
                form
                Rectangle().fill(Palette.line.color).frame(height: 1)
                footer
            }
            .frame(width: 540)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .modalShadow()
            .background {
                Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("providerEditor")
        }
        .onAppear(perform: load)
    }

    // MARK: Header / form / footer

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("MODEL SERVICE").font(FormoraFont.mono(10.5)).tracking(0.6).foregroundStyle(Palette.inkFaint.color)
                Text(title).font(FormoraFont.ui(18, weight: 700)).foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("providerEditor.title")
                Text("API Key 保存在 macOS 钥匙串里，只在调用这家服务商时使用。")
                    .font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color)
            }
            Spacer(minLength: 0)
            IconActionButton(icon: Icons.close, label: "关闭", identifier: "providerEditor.close", action: close)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 17) {
            if isCustom {
                row("名称", problemShown: problem == .nameRequired || problem == .nameTaken) {
                    EditorField(placeholder: "例如：公司模型网关", text: $draft.name, isInvalid: problem == .nameRequired || problem == .nameTaken,
                                identifier: "providerEditor.name")
                }
                row("Base URL", problemShown: problem == .badURL) {
                    EditorField(placeholder: "https://api.example.com/v1（接口后缀不用写，粘了也会自动去掉）", text: $draft.baseURL, mono: true, isInvalid: problem == .badURL,
                                identifier: "providerEditor.baseURL")
                }
                row("API 协议", problemShown: false) { protocolMenu }
            }
            row("API Key", problemShown: problem == .keyRequired) {
                EditorField(placeholder: keyPlaceholder, text: $draft.key, mono: true, secure: !revealsKey,
                            isInvalid: problem == .keyRequired, identifier: "providerEditor.key") {
                    Button { revealsKey.toggle() } label: {
                        IconView(revealsKey ? Icons.eyeOff : Icons.eye, size: 14)
                            .foregroundStyle(Palette.inkMuted.color)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(revealsKey ? "隐藏 API Key" : "显示 API Key")
                    .accessibilityLabel(revealsKey ? "隐藏 API Key" : "显示 API Key")
                    .accessibilityIdentifier("providerEditor.reveal")
                }
            }
            if savedKey != nil {
                Text("留空则继续使用已保存的 Key。")
                    .font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
                    .padding(.leading, 110)
                    .padding(.top, -10)
            }
            toolModeRow
            if test != .idle { connectionBox }
            if let failure {
                InlineError(text: failure, identifier: "providerEditor.failure")
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .onChange(of: draft) { problem = nil; failure = nil; test = .idle }
    }

    /// Optional, so no required mark; the note says what the choice means and which models 自动 already moved.
    private var toolModeRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("工具调用")
                .font(FormoraFont.ui(12, weight: 600))
                .foregroundStyle(Palette.ink.color)
                .frame(width: 96, alignment: .leading)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 7) {
                SegmentedControl(options: ToolCallMode.allCases.map { ($0, $0.label) }, selection: $toolMode,
                                 identifier: "providerEditor.toolMode")
                Text(toolModeNote)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("providerEditor.toolMode.note")
            }
        }
    }

    private var toolModeNote: String {
        guard toolMode == .auto, let providerID else { return toolMode.note }
        let moved = providers.textToolModels(providerID)
        return moved.isEmpty ? toolMode.note : toolMode.note + "已改用兼容模式的模型：" + moved.joined(separator: "、") + "。"
    }

    private var keyPlaceholder: String {
        guard let savedKey else { return "输入 API Key" }
        return revealsKey ? savedKey : ProviderStore.mask(savedKey)
    }

    private var protocolMenu: some View {
        Menu {
            ForEach(APIProtocol.allCases) { value in
                Button(value.rawValue) { draft.apiProtocol = value }
            }
        } label: {
            HStack {
                Text(draft.apiProtocol.rawValue).font(FormoraFont.mono(12)).foregroundStyle(Palette.ink.color)
                Spacer(minLength: 0)
                IconView(Icons.chevronUpDown, size: 13).foregroundStyle(Palette.inkMuted.color)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("providerEditor.protocol")
    }

    /// `.connection-box`: testing (accent), success (green) or failure (alert), in the provider's own words.
    private var connectionBox: some View {
        let (tone, headline, detail): (Color, String, String?) = switch test {
        case .idle, .testing: (Palette.accent.color, "正在测试连接…", nil)
        case .done(let outcome):
            outcome.isConnected
                ? (Palette.success.color, "连接成功", ProviderStatus(outcome).detail)
                : (Palette.alert.color, ProviderStatus(outcome).label, ProviderStatus(outcome).detail)
        }
        return HStack(spacing: 11) {
            Group {
                if test == .testing {
                    ProgressView().controlSize(.small)
                } else {
                    IconView(tone == Palette.success.color ? Icons.check : Icons.alertCircle, size: 15)
                }
            }
            .foregroundStyle(tone)
            .frame(width: 30, height: 30)
            .background(Circle().fill(tone.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                if let detail {
                    Text(detail).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(test == .testing ? Palette.line.color : tone.opacity(0.36), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("providerEditor.connection")
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if confirmingRemoval {
                Text(removalWarning)
                    .font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("取消") { confirmingRemoval = false }.buttonStyle(FormoraButtonStyle(kind: .ghost))
                Button(isCustom ? "确认删除" : "确认清除") { remove() }
                    .buttonStyle(FormoraButtonStyle(kind: .destructive))
                    .accessibilityIdentifier("providerEditor.confirmRemove")
            } else {
                if let removalTitle {
                    let users = providerID.map(providers.usage) ?? 0
                    Button {
                        if needsConfirmation { confirmingRemoval = true } else { remove() }
                    } label: {
                        Label { Text(removalTitle) } icon: { IconView(Icons.trash, size: 14) }
                    }
                    .buttonStyle(FormoraButtonStyle(kind: .destructive))
                    .disabled(users > 0)
                    .help(users > 0 ? ProviderFormProblem.inUse(users).message : removalTitle)
                    .accessibilityIdentifier("providerEditor.remove")
                    if users > 0 {
                        Text(ProviderFormProblem.inUse(users).message)
                            .font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("providerEditor.inUse")
                    }
                }
                Spacer(minLength: 0)
                Button("取消", action: close).buttonStyle(FormoraButtonStyle(kind: .ghost))
                Button("测试连接") { runTest() }
                    .buttonStyle(FormoraButtonStyle())
                    .disabled(test == .testing)
                    .accessibilityIdentifier("providerEditor.test")
                Button("保存配置") { save() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("providerEditor.save")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
    }

    private func row<Field: View>(_ label: String, problemShown: Bool, @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 2) {
                Text(label).font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                Text("*").font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.alert.color)
            }
            .frame(width: 96, alignment: .leading)
            .padding(.top, 9)
            VStack(alignment: .leading, spacing: 0) {
                field()
                if problemShown, let problem { InlineError(text: problem.message, identifier: "providerEditor.problem") }
            }
        }
    }

    // MARK: Removal (S18)

    private var removalTitle: String? {
        guard let providerID else { return nil }
        if isCustom { return "删除服务商" }
        return providers.hasKey(providerID) ? "清除 API Key" : nil
    }

    /// Only a stored key is costly to get back (design spec §8.7 rule 3).
    private var needsConfirmation: Bool { providerID.map(providers.hasKey) ?? false }

    private var removalWarning: String {
        isCustom
            ? "删除后，保存的 API Key 会一起从钥匙串移除，需要重新去服务商后台获取。"
            : "清除后需要重新填写 API Key，这家服务商会回到「未配置」。"
    }

    private func remove() {
        guard let providerID, let entry else { return }
        do {
            if isCustom {
                try providers.deleteCustom(providerID)
                state.toasts.show("已删除「\(entry.name)」")
            } else {
                try providers.clearKey(providerID)
                state.toasts.show("已清除 \(entry.name) 的 API Key")
            }
            state.providerEditor = nil
        } catch {
            confirmingRemoval = false
            failure = (error as? ProviderFormProblem)?.message ?? (error as? KeychainError)?.message ?? error.localizedDescription
        }
    }

    // MARK: Load / test / save

    private func load() {
        if let providerID, let custom = providers.config.custom.first(where: { $0.id == providerID }) {
            draft = CustomProviderDraft(name: custom.name, baseURL: custom.baseURL, apiProtocol: custom.apiProtocol)
        }
        savedKey = providerID.flatMap(providers.savedKey)
        revealsKey = false
        toolMode = providerID.map(providers.toolMode) ?? .auto
    }

    private func runTest() {
        let typed = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = typed.isEmpty ? savedKey : typed else {
            problem = .keyRequired
            return
        }
        let endpoints: [ProviderEndpoint]
        if isCustom {
            guard ProviderStore.isValidBaseURL(draft.baseURL) else {
                problem = .badURL
                return
            }
            endpoints = [ProviderEndpoint(baseURL: draft.baseURL, apiProtocol: draft.apiProtocol)]
        } else {
            endpoints = providerID.map(providers.endpoints) ?? []
        }
        test = .testing
        Task {
            let outcome = await providers.testUnsaved(key: key, endpoints: endpoints)
            test = .done(outcome)
        }
    }

    private func save() {
        do {
            let id: String
            if isCustom {
                id = try providers.saveCustom(draft, editing: providerID)
            } else {
                guard let providerID else { return }
                let typed = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if typed.isEmpty {
                    guard providers.hasKey(providerID) else { throw ProviderFormProblem.keyRequired }
                } else {
                    try providers.saveKey(typed, for: providerID)
                }
                id = providerID
            }
            try providers.setToolMode(toolMode, for: id)
            let name = providers.entry(id)?.name ?? ""
            state.providerEditor = nil
            state.toasts.show("服务商已保存", note: "\(name) 已可用于 Agent 配置")
            // Tests the key, then reads the real list so the row shows the real count.
            Task { await providers.loadModels(id, refresh: true) }
        } catch let formProblem as ProviderFormProblem {
            problem = formProblem
        } catch {
            failure = (error as? KeychainError)?.message ?? error.localizedDescription
        }
    }

    private func close() {
        state.providerEditor = nil
    }
}

/// `.text-input` in dialogs; mono for URLs and keys; optional secure entry and a trailing accessory.
private struct EditorField<Accessory: View>: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false
    var isInvalid = false
    var identifier: String
    @ViewBuilder var accessory: () -> Accessory

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(mono ? FormoraFont.mono(12) : FormoraFont.ui(12))
            .foregroundStyle(Palette.ink.color)
            .focused($isFocused)
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier(identifier)
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(mono ? FormoraFont.mono(12) : FormoraFont.ui(12))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .allowsHitTesting(false)
                }
            }
            accessory()
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isInvalid ? Palette.alert.color : isFocused ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

extension EditorField where Accessory == EmptyView {
    init(placeholder: String, text: Binding<String>, mono: Bool = false, secure: Bool = false, isInvalid: Bool = false,
         identifier: String) {
        self.init(placeholder: placeholder, text: text, mono: mono, secure: secure, isInvalid: isInvalid,
                  identifier: identifier) { EmptyView() }
    }
}
