import SwiftUI

/// Where the cold start is (9f): 「第 2 步，共 4 步」 and four bars, as the creation dialog shows its steps (spec §7.2).
struct SetupProgress: View {
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第 \(step) 步，共 \(LaunchSetup.stepCount) 步")
                .font(FormoraFont.mono(10))
                .foregroundStyle(Palette.inkFaint.color)
            HStack(spacing: 6) {
                ForEach(1...LaunchSetup.stepCount, id: \.self) { index in
                    Capsule().fill(index <= step ? Palette.accent.color : Palette.surfaceRaised2.color).frame(height: 3)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(step) 步，共 \(LaunchSetup.stepCount) 步")
        .accessibilityIdentifier("launch.progress")
    }
}

/// Step 2 (9f): one provider with its key — tested before it is kept — or a ChatGPT sign-in. Skippable.
struct ModelSetupStep: View {
    let state: AppState
    let onDone: (String) -> Void
    let onSkip: () -> Void

    @State private var providerID: String
    @State private var key = ""
    @State private var testing = false
    @State private var failure: String?

    init(state: AppState, onDone: @escaping (String) -> Void, onSkip: @escaping () -> Void) {
        self.state = state
        self.onDone = onDone
        self.onSkip = onSkip
        let choices = Self.choices(state.providers)
        _providerID = State(initialValue: choices.first { $0.id == "deepseek" }?.id ?? choices.first?.id ?? "")
    }

    private var providers: ProviderStore { state.providers }
    private static func choices(_ providers: ProviderStore) -> [ProviderEntry] {
        providers.entries.filter { !$0.isCustom && $0.access == .key }
    }
    private var selected: ProviderEntry? { Self.choices(providers).first { $0.id == providerID } }
    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Rows of 28 with 6 between, five at most — more would scroll.
    private var gridHeight: CGFloat {
        let rows = CGFloat(min((Self.choices(providers).count + 1) / 2, 5))
        return max(rows, 1) * 28 + max(rows - 1, 0) * 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupProgress(step: LaunchSetup.Step.model.rawValue).padding(.bottom, 22)
            StepTitle(title: "配一个模型", detail: "Agent 靠模型思考和干活。选一家服务商，粘贴它的 API Key。")
            FormLabel(text: "服务商")
            // Every key provider at once — ten in two columns, no hidden ones to scroll to.
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                    ForEach(Self.choices(providers)) { entry in providerChip(entry) }
                }
            }
            .frame(height: gridHeight)
            .padding(.bottom, 16)
            FormLabel(text: "API Key")
            KeyField(text: $key, isInvalid: failure != nil, identifier: "launch.model.key")
            if let failure {
                InlineError(text: failure, identifier: "launch.model.failure")
            } else {
                Hint(text: "Key 只存在这台 Mac 的钥匙串里。").padding(.top, 6)
            }
            chatGPT.padding(.top, 14)
            Spacer(minLength: 12)
            StepButtons(primary: testing ? "正在测试…" : "测试并继续", isEnabled: !trimmedKey.isEmpty && !testing,
                        identifier: "launch.model.next", skip: onSkip, action: testAndSave)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: providers.hasKey(ChatGPTAuth.providerID)) { _, signedIn in
            if signedIn { onDone(providers.entry(ChatGPTAuth.providerID)?.name ?? "ChatGPT") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launch.step.model")
    }

    private func providerChip(_ entry: ProviderEntry) -> some View {
        let isSelected = entry.id == providerID
        return Button {
            providerID = entry.id
            failure = nil
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let name = entry.logo, let icon = ProviderLogos.icon(name) {
                        IconView(icon, size: 13)
                    } else {
                        Text(entry.mark).font(FormoraFont.mono(9, weight: 700))
                    }
                }
                .foregroundStyle(isSelected ? Palette.accent.color : Palette.inkMuted.color)
                .frame(width: 18)
                Text(entry.name)
                    .font(FormoraFont.ui(12.5, weight: isSelected ? 600 : 500))
                    .foregroundStyle(isSelected ? Palette.ink.color : Palette.inkMuted.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Palette.accentSoft.color : Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent.color.opacity(0.55) : Palette.line.color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityIdentifier("launch.model.provider.\(entry.id)")
    }

    /// A subscription instead of a key (7i): the sign-in, then its progress or why it failed.
    @ViewBuilder private var chatGPT: some View {
        if let progress = providers.signIns[ChatGPTAuth.providerID] {
            ChatGPTSignInPanel(state: state, progress: progress)
        } else {
            Button { Task { await providers.signInChatGPT() } } label: {
                Text("有 ChatGPT 订阅？用 ChatGPT 账号登录（非官方接入）")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.accent.color)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("launch.model.chatgpt")
        }
    }

    /// Kept only once the provider said yes: a wrong key saved here would fail later, far from where it was typed.
    private func testAndSave() {
        guard let entry = selected, !trimmedKey.isEmpty else { return }
        let key = trimmedKey
        testing = true
        failure = nil
        Task {
            let outcome = await providers.testUnsaved(key: key, endpoints: providers.endpoints(for: entry.id))
            testing = false
            guard outcome.isConnected else {
                failure = ProviderStatus(outcome).detail ?? "连不上\(entry.name)，检查 Key 和网络后再试"
                return
            }
            do {
                try providers.saveKey(key, for: entry.id)
            } catch {
                failure = (error as? ProviderFormProblem)?.message ?? error.localizedDescription
                return
            }
            Task { await providers.loadModels(entry.id) }
            onDone(entry.name)
        }
    }
}

/// Step 3 (9f): the first Agent — a role, 产品设计 by default, and a name — on the model just set up. Skippable.
struct AgentSetupStep: View {
    let state: AppState
    /// The project held for the end: the Agent may work in it.
    let projectID: UUID?
    let onDone: (String) -> Void
    let onSkip: () -> Void

    @State private var roleID = AgentRole.all[0].id
    @State private var name = LaunchSetup.suggestedName(for: AgentRole.all[0].id)
    @State private var providerID: String?
    @State private var modelID = ""
    @State private var readingModels = false
    /// The provider's models, for the menu (user 2026-09-14: the key alone didn't say which model).
    @State private var models: [ModelInfo] = []
    @State private var problem: String?

    private var role: AgentRole { AgentRole.role(roleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupProgress(step: LaunchSetup.Step.agent.rawValue).padding(.bottom, 22)
            StepTitle(title: "建第一个 Agent", detail: "先建一个就能开始干活，其余岗位用到再建。")
            FormLabel(text: "岗位")
            FlowLayout(spacing: 8) {
                ForEach(AgentRole.all) { option in roleChip(option) }
            }
            Hint(text: role.summary).padding(.top, 8).padding(.bottom, 18)
            FormLabel(text: "名字")
            FormoraTextField(placeholder: "给它起个名字", text: $name, isInvalid: problem != nil, identifier: "launch.agent.name")
            if let problem { InlineError(text: problem, identifier: "launch.agent.problem") }
            if providerID != nil {
                FormLabel(text: "模型").padding(.top, 14)
                modelMenu
            }
            Hint(text: modelLine).padding(.top, 10)
            Spacer(minLength: 12)
            StepButtons(primary: "创建并继续", isEnabled: projectID != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && !readingModels,
                        identifier: "launch.agent.next", skip: onSkip, action: create)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task { await pickModel() }
        .onChange(of: roleID) { old, new in
            // A name the user didn't touch follows the role.
            if name == LaunchSetup.suggestedName(for: old) { name = LaunchSetup.suggestedName(for: new) }
        }
        .onChange(of: name) { problem = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launch.step.agent")
    }

    private var modelLine: String {
        guard let providerID else { return "还没配模型：先建好，之后在「Agent」页给它选一个。" }
        if readingModels { return "正在读取模型列表…" }
        let provider = state.providers.entry(providerID)?.name ?? providerID
        return modelID.isEmpty ? "用 \(provider)，模型之后在「Agent」页选。" : "用 \(provider) 的这个模型，之后可以在「Agent」页改。"
    }

    /// The provider's models; the first is chosen until the user picks another.
    private var modelMenu: some View {
        Menu {
            ForEach(models) { model in
                Button { modelID = model.id } label: {
                    if model.id == modelID {
                        Label(model.name ?? model.id, systemImage: "checkmark")
                    } else {
                        Text(model.name ?? model.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(readingModels ? "正在读取模型列表…" : (models.first { $0.id == modelID }?.name ?? (modelID.isEmpty ? "选一个模型" : modelID)))
                    .font(FormoraFont.mono(12))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                IconView(Icons.chevronUpDown, size: 11).foregroundStyle(Palette.inkFaint.color)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(readingModels || models.isEmpty)
        .accessibilityIdentifier("launch.agent.model")
    }

    private func roleChip(_ option: AgentRole) -> some View {
        let isSelected = option.id == roleID
        return Button { roleID = option.id } label: {
            Text(option.name)
                .font(FormoraFont.ui(12.5, weight: isSelected ? 600 : 500))
                .foregroundStyle(isSelected ? Palette.accent.color : Palette.inkMuted.color)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Capsule().fill(isSelected ? Palette.accentSoft.color : Palette.surfaceRaised.color))
                .overlay(Capsule().strokeBorder(isSelected ? Palette.accent.color.opacity(0.55) : Palette.line.color, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("launch.agent.role.\(option.id)")
    }

    /// The first provider with a key, its first model — as the creation dialog starts (7.2).
    private func pickModel() async {
        let providers = state.providers
        guard let entry = providers.entries.first(where: { providers.hasKey($0.id) }) else { return }
        providerID = entry.id
        readingModels = true
        await providers.loadModels(entry.id)
        readingModels = false
        if case .loaded(let listed) = providers.modelLists[entry.id], !listed.isEmpty {
            models = listed
        } else {
            models = entry.commonModels
        }
        modelID = models.first?.id ?? ""
    }

    private func create() {
        guard let projectID else { return }
        do {
            let agent = try state.agents.create(NewAgent(roleID: roleID, name: name, subtitle: role.summary, avatarPNG: nil,
                                                         providerID: providerID, modelID: modelID, projectIDs: [projectID]))
            onDone(agent.displayName)
        } catch {
            problem = (error as? AgentProblem)?.message ?? error.localizedDescription
        }
    }
}

/// Step 4 (9f): what is set up, what isn't and where to go for it, and where to ask. The project opens on 开始使用.
struct ReadyStep: View {
    let projectName: String?
    let providerName: String?
    let agentName: String?
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SetupProgress(step: LaunchSetup.Step.ready.rawValue).padding(.bottom, 34)
            IconView(Icons.check, size: 24)
                .foregroundStyle(Palette.success.color)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.successSoft.color))
                .padding(.bottom, 18)
            Text("准备好了")
                .font(FormoraFont.ui(21, weight: 700))
                .tracking(-0.21)
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, 8)
            Text("有问题可以问设置里的 Bob：右下角那个圆形按钮。")
                .font(FormoraFont.ui(13))
                .foregroundStyle(Palette.inkMuted.color)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 10) {
                row("项目", projectName ?? "—", isSet: projectName != nil)
                row("模型", providerName ?? "还没配，之后去「设置 → 模型」", isSet: providerName != nil)
                row("Agent", agentName ?? "还没建，之后去「Agent」新建", isSet: agentName != nil)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
            .padding(.bottom, 26)
            Button("开始使用", action: onStart)
                .buttonStyle(FormoraButtonStyle(kind: .primary, fillsWidth: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("launch.start")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launch.step.ready")
    }

    private func row(_ label: String, _ value: String, isSet: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(FormoraFont.mono(11))
                .foregroundStyle(Palette.inkFaint.color)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(FormoraFont.ui(12.5, weight: isSet ? 600 : 400))
                .foregroundStyle(isSet ? Palette.ink.color : Palette.inkMuted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StepTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(FormoraFont.ui(21, weight: 700))
                .tracking(-0.21)
                .foregroundStyle(Palette.ink.color)
            Text(detail)
                .font(FormoraFont.ui(13))
                .foregroundStyle(Palette.inkMuted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 20)
    }
}

private struct Hint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FormoraFont.ui(11.5))
            .foregroundStyle(Palette.inkFaint.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 跳过 and the step's own action, as the new-project form lays out its two buttons.
private struct StepButtons: View {
    let primary: String
    let isEnabled: Bool
    let identifier: String
    let skip: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button("跳过", action: skip)
                .buttonStyle(FormoraButtonStyle(kind: .standard, fillsWidth: true))
                .accessibilityIdentifier("launch.skip")
            Button(primary, action: action)
                .buttonStyle(FormoraButtonStyle(kind: .primary, fillsWidth: true))
                .disabled(!isEnabled)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// The key, hidden as typed — the form's field, secure.
private struct KeyField: View {
    @Binding var text: String
    let isInvalid: Bool
    let identifier: String

    var body: some View {
        let metrics = FieldMetrics.form
        SecureField("", text: $text, prompt: Text("粘贴 API Key").foregroundColor(Palette.inkFaint.color))
            .textFieldStyle(.plain)
            .font(FormoraFont.mono(12.5))
            .foregroundStyle(Palette.ink.color)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(height: metrics.height)
            .background(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(isInvalid ? Palette.alert.color : Palette.lineStrong.color, lineWidth: 1))
            .accessibilityIdentifier(identifier)
    }
}
