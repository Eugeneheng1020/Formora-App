import AppKit
import SwiftUI

/// Creating an Agent in three steps (design spec §7.2): identity → model → projects. The scrim doesn't close
/// it; Esc and ✕ close and discard without asking; nothing closes it while creating.
struct CreateAgentDialog: View {
    let state: AppState
    let session: ProjectSession

    @State private var flow: CreateAgentFlow
    @State private var avatarPreview: NSImage?

    init(state: AppState, session: ProjectSession) {
        self.state = state
        self.session = session
        _flow = State(initialValue: state.createAgentPreset
            ?? CreateAgentFlow(agents: state.agents, providers: state.providers, currentProject: session.current?.id))
    }

    private var providers: ProviderStore { state.providers }
    private var role: AgentRole { AgentRole.role(flow.roleID) }

    var body: some View {
        ZStack {
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.line.color).frame(height: 1)
                ScrollView {
                    Group {
                        switch flow.step {
                        case .identity: identityStep
                        case .model: modelStep
                        case .projects: projectStep
                        }
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Palette.line.color).frame(height: 1)
                footer
            }
            .frame(width: 680)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .modalShadow()
            .background {
                Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("createAgent")
        }
    }

    // MARK: Header / footer

    private var header: some View {
        let titles = ["定义 Agent 身份", "配置模型", "授权项目"]
        let subtitles = ["选择职责角色，并设置在列表中显示的名称、副标题和头像。", "选择服务商与模型；测试连接为可选操作。",
                         "选择项目访问范围，创建后 Agent 将立即激活。"]
        let index = flow.step.rawValue - 1
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text("STEP \(flow.step.rawValue) / 3").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
                    .padding(.bottom, 5)
                Text(titles[index]).font(FormoraFont.ui(18, weight: 700)).foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("createAgent.title")
                Text(subtitles[index]).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color).padding(.top, 5)
                HStack(spacing: 6) {
                    ForEach(1...3, id: \.self) { step in
                        Capsule().fill(step <= flow.step.rawValue ? Palette.accent.color : Palette.surfaceRaised2.color).frame(height: 3)
                    }
                }
                .padding(.top, 15)
            }
            IconActionButton(icon: Icons.close, label: "关闭", identifier: "createAgent.close", action: close)
                .disabled(flow.isCreating)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let note = footnote {
                Text(note).font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
            }
            Spacer(minLength: 0)
            HStack(spacing: 9) {
                if flow.step != .identity {
                    Button("上一步") { back() }.buttonStyle(FormoraButtonStyle(kind: .ghost)).disabled(flow.isCreating)
                        .accessibilityIdentifier("createAgent.back")
                }
                if flow.step == .model {
                    Button("测试连接") { runTest() }
                        .buttonStyle(FormoraButtonStyle())
                        .disabled(flow.connection == .testing || !providerReady || flow.model.trimmedModelID.isEmpty)
                        .accessibilityIdentifier("createAgent.test")
                }
                Button(primaryTitle) { advance() }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(flow.isCreating || (flow.step == .model && !flow.canLeaveModelStep(isConfigured: providers.hasKey)))
                    .accessibilityIdentifier("createAgent.next")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 24)
    }

    private var footnote: String? {
        switch flow.step {
        case .identity: "所有配置仅保存在本机"
        case .model: if case .success = flow.connection { "连接验证已通过" } else { nil }
        case .projects: nil
        }
    }

    private var primaryTitle: String {
        if flow.step != .projects { return "下一步" }
        return flow.isCreating ? "创建中" : "创建 Agent"
    }

    // MARK: Step 1 — identity

    private var identityStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("选择角色", note: "角色决定 Agent 的职责模板；每个角色最多创建 \(AgentRole.limit) 个。")
            HStack(spacing: 8) {
                ForEach(AgentRole.all) { option in roleCard(option) }
            }
            .padding(.bottom, 8)
            RoleSubtitleField(text: $flow.subtitle, fallback: role.summary)
                .padding(.leading, 10)
                .padding(.bottom, 18)
            sectionTitle("定义身份", note: nil)
            formRow("名称", required: true) {
                VStack(alignment: .leading, spacing: 0) {
                    InputField(placeholder: "例如：前端", text: $flow.name, height: 38, isInvalid: flow.nameProblem != nil,
                               identifier: "createAgent.name")
                        .onChange(of: flow.name) { flow.nameProblem = nil }
                    HStack(alignment: .top, spacing: 12) {
                        if let problem = flow.nameProblem {
                            Text(problem.message).font(FormoraFont.ui(10.5)).foregroundStyle(Palette.alert.color)
                                .accessibilityIdentifier("createAgent.nameProblem")
                        }
                        Spacer(minLength: 0)
                        Text("\(flow.name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)/\(AgentStore.maxNameLength)")
                            .font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
                    }
                    .frame(minHeight: 18)
                    .padding(.top, 5)
                }
            }
            formRow("头像", required: false) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        AgentAvatar(image: avatarPreview, initial: role.initial, size: 56)
                        CircleIconButton(icon: Icons.upload, label: "选择头像图片", identifier: "createAgent.avatar", action: pickAvatar)
                    }
                    Text(flow.avatarProblem ?? "PNG、JPEG 或 HEIC，不超过 10 MB；自动居中裁剪。")
                        .font(FormoraFont.ui(10.5))
                        .foregroundStyle(flow.avatarProblem == nil ? Palette.inkFaint.color : Palette.alert.color)
                }
            }
        }
    }

    /// `.role-option`: 92 tall, five equal cards; a full role is disabled with its count.
    private func roleCard(_ option: AgentRole) -> some View {
        let count = state.agents.count(ofRole: option.id)
        let isOn = option.id == flow.roleID
        let isFull = count >= AgentRole.limit
        return Button { flow.chooseRole(option) } label: {
            VStack(spacing: 5) {
                Text(option.initial)
                    .font(FormoraFont.ui(12, weight: 700))
                    .foregroundStyle(isOn ? Palette.accentInk.color : Palette.inkMuted.color)
                    .frame(width: 34, height: 34)
                    .background(AvatarShape().fill(isOn ? Palette.accent.color : Palette.surfaceRaised2.color))
                Text(option.name).font(FormoraFont.ui(11.5, weight: 600)).lineLimit(1)
                Text(isFull ? "已达上限 \(count)/\(AgentRole.limit)" : "\(count)/\(AgentRole.limit)")
                    .font(FormoraFont.mono(9))
                    .foregroundStyle(isOn ? Palette.inkMuted.color : Palette.inkFaint.color)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Palette.ink.color : Palette.inkMuted.color)
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOn ? Palette.accentSoft.color : Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isOn ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isFull)
        .opacity(isFull ? 0.42 : 1)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("createAgent.role.\(option.id)")
    }

    // MARK: Step 2 — model

    private var providerReady: Bool { flow.model.providerID.map(providers.hasKey) ?? false }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("选择服务商", note: "API Key 在「设置 → 模型」中统一维护，创建时不会重复索取。")
            formRow("服务商", required: true) {
                ProviderMenu(providers: providers, selection: flow.model.providerID, height: 38, identifier: "createAgent.provider") { id in
                    flow.model.providerID = id
                    flow.model.modelID = ""
                    flow.model.source = .list
                    flow.modelChanged()
                }
            }
            sectionTitle("选择模型", note: nil)
            ModelSourceControl(source: Binding(get: { flow.model.source },
                                               set: { flow.model.source = $0; flow.modelChanged() }),
                               identifier: "createAgent.modelSource")
                .padding(.bottom, 14)
            formRow("Model ID", required: true) {
                ModelIDField(providers: providers, providerID: flow.model.providerID, source: flow.model.source,
                             modelID: Binding(get: { flow.model.modelID },
                                              set: { flow.model.modelID = $0; flow.modelChanged() }),
                             height: 38, identifier: "createAgent.modelID")
            }
            connectionBox
        }
        .task(id: flow.model.providerID) { await pickFirstModel() }
    }

    /// The mockup's `connectionView`: idle, testing, success, failure, timeout, provider not configured.
    @ViewBuilder private var connectionBox: some View {
        if let providerID = flow.model.providerID, !providers.hasKey(providerID) {
            ConnectionBox(tone: .error, title: "服务商未配置", note: "请先在「设置 → 模型」中填写 API Key。") {
                Button("配置") { state.providerEditor = .provider(providerID) }
                    .buttonStyle(FormoraButtonStyle())
                    .accessibilityIdentifier("createAgent.configureProvider")
            }
        } else if flow.model.providerID == nil {
            ConnectionBox(tone: .error, title: "还没有选择服务商", note: "先在上面选择一家已经配置了 API Key 的服务商。") { EmptyView() }
        } else {
            switch flow.connection {
            case .idle:
                ConnectionBox(tone: .idle, title: "尚未测试连接", note: "可直接继续，或先测试该模型是否可用。") { EmptyView() }
            case .testing:
                ConnectionBox(tone: .testing, title: "正在测试连接", note: "最长等待 10 秒，请勿关闭窗口。") { EmptyView() }
            case .success(_, let note):
                ConnectionBox(tone: .success, title: "连接成功",
                              note: note ?? "\(providers.entry(flow.model.providerID ?? "")?.name ?? "") / \(flow.model.trimmedModelID) 可用。") { EmptyView() }
            case .failed(let message):
                ConnectionBox(tone: .error, title: "连接失败", note: message) { EmptyView() }
            case .timedOut:
                ConnectionBox(tone: .error, title: "连接超时", note: "10 秒内未收到响应，请检查网络、Base URL 或服务商状态。") { EmptyView() }
            }
        }
    }

    // MARK: Step 3 — projects

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("授权项目", note: "Agent 全局保存，但只能读取已授权项目；至少选择 1 个项目。")
            VStack(spacing: 0) {
                ForEach(session.projects) { project in
                    ProjectCheckRow(name: project.name, isOn: flow.projectIDs.contains(project.id),
                                    isCurrent: project.id == session.current?.id, identifier: "createAgent.project.\(project.name)") {
                        if flow.projectIDs.contains(project.id) { flow.projectIDs.remove(project.id) } else { flow.projectIDs.insert(project.id) }
                        flow.projectProblem = false
                    }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            if flow.projectProblem {
                InlineError(text: AgentProblem.noProject.message, identifier: "createAgent.projectProblem").padding(.top, 3)
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(FormoraFont.ui(12, weight: 700)).foregroundStyle(Palette.ink.color).padding(.bottom, note == nil ? 10 : 6)
            if let note {
                Text(note).font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color).lineSpacing(3).padding(.bottom, 13)
            }
        }
    }

    /// `.form-field-row`: 96pt label, 14pt gap, 17pt below.
    private func formRow<Field: View>(_ label: String, required: Bool, @ViewBuilder field: () -> Field) -> some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 2) {
                Text(label).font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                if required { Text("*").font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.alert.color) }
            }
            .frame(width: 96, alignment: .leading)
            .padding(.top, 10)
            field().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 17)
    }

    // MARK: Actions

    private func close() {
        guard !flow.isCreating else { return }
        state.isCreatingAgent = false
        state.createAgentPreset = nil
    }

    private func back() {
        guard let previous = CreateAgentFlow.Step(rawValue: flow.step.rawValue - 1) else { return }
        flow.projectProblem = false
        flow.step = previous
    }

    private func advance() {
        switch flow.step {
        case .identity:
            flow.subtitle = AgentStore.finalSubtitle(flow.subtitle, role: role)
            if state.agents.count(ofRole: role.id) >= AgentRole.limit {
                flow.nameProblem = .roleFull(role.name)
            } else {
                flow.nameProblem = state.agents.nameProblem(flow.name)
            }
            guard flow.nameProblem == nil, flow.avatarProblem == nil else { return }
            flow.name = flow.name.trimmingCharacters(in: .whitespacesAndNewlines)
            flow.step = .model
        case .model:
            guard flow.canLeaveModelStep(isConfigured: providers.hasKey) else { return }
            flow.step = .projects
        case .projects:
            create()
        }
    }

    private func create() {
        let projectIDs = session.projects.map(\.id).filter(flow.projectIDs.contains)
        guard !projectIDs.isEmpty else {
            flow.projectProblem = true
            return
        }
        flow.isCreating = true
        do {
            let agent = try state.agents.create(NewAgent(roleID: flow.roleID, name: flow.name, subtitle: flow.subtitle,
                                                         avatarPNG: flow.avatarPNG, providerID: flow.model.providerID,
                                                         modelID: flow.model.trimmedModelID, projectIDs: projectIDs))
            state.selectedAgentID = agent.id
            state.agentTab = .overview
            state.select(.agents)
            state.isCreatingAgent = false
            state.createAgentPreset = nil
            state.toasts.show("Agent 创建成功", note: "\(agent.displayName) 已激活", seconds: 3)
        } catch {
            flow.isCreating = false
            if let problem = error as? AgentProblem, flow.step == .projects, problem != .noProject {
                flow.step = .identity
                flow.nameProblem = problem
            } else {
                state.toasts.show("没有创建 Agent", note: (error as? AgentProblem)?.message ?? error.localizedDescription, isError: true)
            }
        }
    }

    private func pickAvatar() {
        guard let url = pickAvatarImage() else { return }
        do {
            let png = try AvatarImage.prepare(from: url)
            flow.avatarPNG = png
            flow.avatarProblem = nil
            avatarPreview = NSImage(data: png)
        } catch {
            flow.avatarPNG = nil
            avatarPreview = nil
            flow.avatarProblem = (error as? AvatarImage.Problem)?.message ?? "图片读取失败，请重新选择"
        }
    }

    private func runTest() {
        guard let providerID = flow.model.providerID else { return }
        let modelID = flow.model.trimmedModelID
        let fingerprint = flow.fingerprint
        flow.connection = .testing
        Task {
            let outcome = await providers.testModel(providerID: providerID, modelID: modelID)
            guard flow.fingerprint == fingerprint else { return } // changed while testing
            switch outcome {
            case .connected(let note): flow.connection = .success(fingerprint: fingerprint, note: note)
            case .timedOut: flow.connection = .timedOut
            default: flow.connection = .failed(ProviderStatus(outcome).detail ?? "服务商拒绝了请求，请检查全局 API Key 后重试。")
            }
        }
    }

    /// 「全部模型」 starts on the provider's first real model; a provider without a list switches to a custom ID.
    private func pickFirstModel() async {
        guard let providerID = flow.model.providerID, providers.hasKey(providerID) else { return }
        await providers.loadModels(providerID)
        guard flow.model.providerID == providerID, flow.model.modelID.isEmpty else { return }
        switch providers.modelLists[providerID] {
        case .loaded(let models): flow.model.modelID = models.first?.id ?? ""
        case .unsupported: flow.model.source = .custom
        default: break
        }
    }
}

/// `.role-selection-summary`: the subtitle, edited in place, with a 2pt accent mark 8pt to its left.
/// Typing past 50 code points has no effect; leaving it empty restores the role's default (spec §7.1).
private struct RoleSubtitleField: View {
    @Binding var text: String
    let fallback: String

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(FormoraFont.ui(11))
            .foregroundStyle(Palette.inkMuted.color)
            .focused($isFocused)
            .padding(.horizontal, 11)
            .frame(minHeight: 34)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isFocused ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Palette.accent.color).frame(width: 2).offset(x: -10)
            }
            .onChange(of: text) { old, new in if AgentStore.acceptSubtitle(new) == nil { text = old } }
            .onChange(of: isFocused) { _, focused in
                if !focused, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = fallback }
            }
            .accessibilityLabel("副标题")
            .accessibilityIdentifier("createAgent.subtitle")
    }
}
