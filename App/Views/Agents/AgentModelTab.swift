import SwiftUI

/// 模型与权限 (spec §8.5): the model and fallbacks are a draft with an explicit save; project access saves as
/// it changes. The API Key row appears only when the provider has no key (user 2026-09-08). No 测试连接 here
/// (user 2026-09-12, D62): the model is tested when the Agent is created, and every reply tests it anyway.
struct AgentModelTab: View {
    let state: AppState
    let session: ProjectSession
    let agent: AgentRecord

    private var providers: ProviderStore { state.providers }

    private var draft: AgentModelDraft {
        state.modelDrafts[agent.id] ?? AgentModelDraft(agent: agent, knownModels: knownModels(agent.providerID))
    }

    private var isDirty: Bool { state.hasUnsavedDraft(agent.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelBlock
            fallbackBlock
            approvalBlock
            projectBlock
        }
    }

    // MARK: 权限模式

    /// 7b, L5: how far the Agent goes without asking; saved as it changes, like 项目权限.
    private var approvalBlock: some View {
        DetailBlock(title: "权限模式", note: "这个 Agent 动手之前要不要先问你；修改后自动保存。") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                SegmentedControl(options: ApprovalMode.allCases.map { ($0, $0.label) },
                                 selection: Binding(get: { agent.approvalMode }, set: { setApprovalMode($0) }),
                                 identifier: "agent.approvalMode")
                Text(agent.approvalMode.note)
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent.approvalMode.note")
                // 10h: 旁审 (7d's 写完自审 before) — every look is a model call, so it can be turned off.
                HStack(alignment: .top, spacing: 11) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("旁审").font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                        Text("另一个模型在旁边看它干活：改完文件、跑完命令的每一步和最后的回答都看一眼，没问题不出声，有问题提醒它。用「设置 → Bob」选的模型，没选就用它自己的。每看一次多一次模型调用。")
                            .font(FormoraFont.ui(11.5))
                            .foregroundStyle(Palette.inkMuted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    FormoraSwitch(isOn: Binding(get: { agent.reviewsOwnWork }, set: { setReviewsOwnWork($0) }),
                                  label: "旁审", identifier: "agent.reviewsOwnWork")
                }
                .padding(.top, 8)
                computerRow
            }
        }
    }

    /// 7j, B3: computer use, off by default. A build without it keeps the switch off and says why; with it on and a
    /// permission missing, the row says which and offers 设置 → 电脑操作.
    private var computerRow: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("允许操作电脑").font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                    if !ComputerBuild.isAvailable { SmallTag(text: "只有官网版能用") }
                }
                Text("看屏幕、点按和打字、用脚本控制其他应用。第一次动手前会先问你，屏幕顶部随时能停。")
                    .font(FormoraFont.ui(11.5))
                    .foregroundStyle(Palette.inkMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
                if ComputerBuild.isAvailable, agent.allowsComputer, !state.computer.missing.isEmpty {
                    HStack(spacing: 8) {
                        Text("还缺系统权限：\(state.computer.missing.map(\.title).joined(separator: "、"))")
                            .font(FormoraFont.ui(11.5))
                            .foregroundStyle(Palette.alert.color)
                        Button("去设置") {
                            state.settingsCategory = .computer
                            state.select(.settings)
                        }
                        .buttonStyle(FormoraButtonStyle(kind: .ghost))
                        .accessibilityIdentifier("agent.computer.permissions")
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            FormoraSwitch(isOn: Binding(get: { ComputerBuild.isAvailable && agent.allowsComputer }, set: { setAllowsComputer($0) }),
                          label: "允许操作电脑", identifier: "agent.allowsComputer")
                .disabled(!ComputerBuild.isAvailable)
        }
        .padding(.top, 8)
        .task(id: agent.allowsComputer) {
            if ComputerBuild.isAvailable, agent.allowsComputer { await state.computer.refresh() }
        }
    }

    private func setAllowsComputer(_ isOn: Bool) {
        do {
            try state.agents.setAllowsComputer(agent, isOn)
            state.toasts.show("已保存", note: isOn ? "允许操作电脑：开" : "允许操作电脑：关", seconds: 2)
        } catch {
            state.toasts.show("没有更改", note: error.localizedDescription, isError: true)
        }
    }

    private func setReviewsOwnWork(_ isOn: Bool) {
        do {
            try state.agents.setReviewsOwnWork(agent, isOn)
            state.toasts.show("已保存", note: isOn ? "旁审：开" : "旁审：关", seconds: 2)
        } catch {
            state.toasts.show("没有更改", note: error.localizedDescription, isError: true)
        }
    }

    private func setApprovalMode(_ mode: ApprovalMode) {
        guard mode != agent.approvalMode else { return }
        do {
            try state.agents.setApprovalMode(agent, mode)
            state.toasts.show("已保存", note: "权限模式：\(mode.label)", seconds: 2)
        } catch {
            state.toasts.show("没有更改", note: error.localizedDescription, isError: true)
        }
    }

    // MARK: 模型

    private var modelBlock: some View {
        DetailBlock(title: "模型", note: "保存后的新任务使用新配置；运行中任务继续使用启动时快照。") {
            SaveState(isDirty: isDirty)
            Button("保存模型配置") { save() }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .disabled(!isDirty || draft.problem(isConfigured: providers.hasKey) != nil)
                .accessibilityIdentifier("agent.saveModel")
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        FormLabelCell(text: "服务商")
                        ProviderMenu(providers: providers, selection: draft.providerID, identifier: "agent.provider") { id in
                            update { $0.providerID = id; $0.modelID = ""; $0.source = .list }
                        }
                    }
                    GridRow {
                        FormLabelCell(text: "模型来源")
                        ModelSourceControl(source: binding(\.source), identifier: "agent.modelSource")
                    }
                    GridRow {
                        FormLabelCell(text: "Model ID")
                        ModelIDField(providers: providers, providerID: draft.providerID, source: draft.source,
                                     modelID: binding(\.modelID), identifier: "agent.modelID")
                    }
                }
                ModelMetaStrip(info: providers.modelInfo(draft.providerID, draft.trimmedModelID))
                    .padding(.top, 14)
                if let providerID = draft.providerID, !providers.hasKey(providerID) { apiKeyRow }
                if isDirty, let problem = draft.problem(isConfigured: providers.hasKey) {
                    InlineError(text: problem, identifier: "agent.modelProblem")
                }
            }
        }
    }

    /// `.api-status-row` — only when something is missing (D62).
    private var apiKeyRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("API Key 未配置").font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.alert.color)
                Text("密钥只在「设置 → 模型」中维护，当前 Agent 不保存覆盖值。")
                    .font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
            }
            Spacer(minLength: 0)
            // A round trip the user asked for: not guarded, and the draft stays (spec §8.6).
            Button("前往模型设置") {
                state.settingsCategory = .models
                state.select(.settings)
            }
            .buttonStyle(FormoraButtonStyle())
            .accessibilityIdentifier("agent.openModelSettings")
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.apiKeyRow")
    }

    // MARK: 备用模型

    private var fallbackBlock: some View {
        DetailBlock(title: "备用模型", note: "主模型限流、配额不足或服务不可用时，按顺序切换；最多 3 个。") {
            Button("添加备用模型") { addFallback() }
                .buttonStyle(FormoraButtonStyle())
                .disabled(draft.fallbacks.count >= 3)
                .accessibilityIdentifier("agent.addFallback")
        } content: {
            if draft.fallbacks.isEmpty {
                Text("还没有备用模型。").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(draft.fallbacks.enumerated()), id: \.offset) { index, fallback in
                        fallbackRow(index, fallback)
                    }
                }
            }
        }
    }

    /// `.fallback-row`: index, provider, model, remove. A provider that lost its key keeps the entry, marked.
    private func fallbackRow(_ index: Int, _ fallback: ModelReference) -> some View {
        HStack(spacing: 9) {
            Text("\(index + 1)").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color).frame(width: 24, alignment: .leading)
            ProviderMenu(providers: providers, selection: fallback.providerID, identifier: "agent.fallback.\(index).provider") { id in
                update { $0.fallbacks[index] = ModelReference(providerID: id, modelID: "") }
            }
            .frame(maxWidth: 240)
            ModelIDField(providers: providers, providerID: fallback.providerID, source: fallbackSource(fallback),
                         modelID: Binding(get: { draft.fallbacks.indices.contains(index) ? draft.fallbacks[index].modelID : "" },
                                          set: { value in update { if $0.fallbacks.indices.contains(index) { $0.fallbacks[index].modelID = value } } }),
                         identifier: "agent.fallback.\(index).model")
            if !providers.hasKey(fallback.providerID) {
                Text("不可用").font(FormoraFont.mono(10)).foregroundStyle(Palette.alert.color)
            }
            IconActionButton(icon: Icons.close, label: "移除备用模型", identifier: "agent.fallback.\(index).remove") {
                update { $0.fallbacks.remove(at: index) }
            }
        }
    }

    /// Fallbacks pick from the real list when the provider has one, otherwise take a typed ID.
    private func fallbackSource(_ fallback: ModelReference) -> AgentModelDraft.Source {
        if case .unsupported = providers.modelLists[fallback.providerID] { return .custom }
        return .list
    }

    // MARK: 项目权限

    private var projectBlock: some View {
        let projects = session.projects
        let granted = projects.filter { agent.projectIDs.contains($0.id) }.count
        return DetailBlock(title: "项目权限", note: "至少保留 1 个授权项目；修改后自动保存。", isLast: true) {
            BlockMeta(text: "\(granted) 个项目")
        } content: {
            VStack(spacing: 0) {
                ForEach(projects) { project in
                    ProjectCheckRow(name: project.name, isOn: agent.projectIDs.contains(project.id),
                                    isCurrent: project.id == session.current?.id,
                                    identifier: "agent.project.\(project.name)") {
                        toggle(project)
                    }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        }
    }

    private func toggle(_ project: ProjectRecord) {
        var ids = agent.projectIDs.filter { id in session.projects.contains { $0.id == id } }
        if let index = ids.firstIndex(of: project.id) {
            guard ids.count > 1 else {
                state.toasts.show("至少保留 1 个项目", note: "项目授权未修改", isError: true)
                return
            }
            ids.remove(at: index)
        } else {
            ids.append(project.id)
        }
        try? state.agents.setProjects(agent, to: ids)
        state.toasts.show("已保存", note: "项目权限已更新", seconds: 2)
    }

    // MARK: Draft

    private func knownModels(_ providerID: String?) -> [String] {
        guard let providerID else { return [] }
        var ids = providers.entry(providerID)?.commonModels.map(\.id) ?? []
        if case .loaded(let models) = providers.modelLists[providerID] { ids += models.map(\.id) }
        return ids
    }

    private func update(_ change: (inout AgentModelDraft) -> Void) {
        var next = draft
        change(&next)
        state.modelDrafts[agent.id] = next
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentModelDraft, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func addFallback() {
        let provider = draft.providerID.flatMap { providers.hasKey($0) ? $0 : nil }
            ?? providers.entries.first { providers.hasKey($0.id) }?.id
        guard let provider else {
            state.toasts.show("没有可用的服务商", note: "先在「设置 → 模型」配置一个服务商", isError: true)
            return
        }
        update { $0.fallbacks.append(ModelReference(providerID: provider, modelID: "")) }
    }

    private func save() {
        do {
            try state.agents.saveModel(agent, draft, isConfigured: providers.hasKey)
            state.modelDrafts[agent.id] = nil
            state.toasts.show("模型配置已保存", note: "新任务将使用这套配置")
        } catch {
            state.toasts.show("模型配置未保存", note: (error as? AgentProblem)?.message ?? error.localizedDescription, isError: true)
        }
    }
}
