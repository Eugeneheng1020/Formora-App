import SwiftUI

/// The Agent's MCP tab (spec §8.4): servers are configured once in 设置; each Agent chooses which it may use
/// and which of their tools. Only enabled servers whose last test connected can be switched on. Explicit
/// save — switching tools mid-task would change what a running conversation can do.
struct AgentMCPTab: View {
    let state: AppState
    let agent: AgentRecord

    private var store: MCPStore { state.mcp }
    private var draft: [MCPAccess] { state.mcpDrafts[agent.id] ?? agent.mcpAccess }
    private var isDirty: Bool { state.hasUnsavedDraft(agent.id) && draft != agent.mcpAccess }

    var body: some View {
        DetailBlock(title: "MCP", note: "服务由全局维护；当前 Agent 独立选择可用工具。", isLast: true) {
            SaveState(isDirty: isDirty)
            Button("全局设置") {
                state.settingsCategory = .mcp
                state.select(.settings) // a round trip the user asked for — not guarded (spec §8.6)
            }
            .buttonStyle(FormoraButtonStyle())
            .accessibilityIdentifier("agent.mcp.settings")
            Button("保存 MCP 配置") { save() }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .disabled(!isDirty || problem != nil)
                .accessibilityIdentifier("agent.mcp.save")
        } content: {
            if store.servers.isEmpty {
                Text("还没有 MCP 服务。去「设置 → MCP」添加。")
                    .font(FormoraFont.ui(12)).foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(store.servers) { server in row(server) }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    if let problem { InlineError(text: problem, identifier: "agent.mcp.problem").padding(.top, 8) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent.mcp.list")
            }
        }
    }

    private func row(_ server: MCPServerConfig) -> some View {
        let access = draft.first { $0.serverID == server.id }
        let usable = store.isUsable(server.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                CapabilityMark(text: server.mark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                    Text("\(server.transportLabel) · \(server.endpointSummary)")
                        .font(FormoraFont.mono(11)).foregroundStyle(Palette.inkMuted.color).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        MCPStatusLine(status: store.status(of: server.id))
                        if usable, !server.tools.isEmpty { SmallTag(text: "\(server.tools.count) 个工具") }
                    }
                    .padding(.top, 4)
                    if !usable, access == nil {
                        Text("先在「设置 → MCP」启用并测试连接成功，才能在这里打开")
                            .font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).padding(.top, 2)
                    } else if !usable {
                        Text("这个服务现在不可用，保留原来的授权，等你在「设置 → MCP」恢复连接")
                            .font(FormoraFont.ui(11)).foregroundStyle(Palette.alert.color).padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FormoraSwitch(isOn: Binding(get: { access != nil }, set: { toggle(server, $0) }),
                              isEnabled: usable || access != nil,
                              label: "允许 \(agent.displayName) 使用 \(server.name)", identifier: "agent.mcp.\(server.id)")
            }
            if let access {
                VStack(alignment: .leading, spacing: 10) {
                    SegmentedControl(options: [(MCPAccess.Mode.all, "全部工具"), (.selected, "指定工具")],
                                     selection: Binding(get: { access.mode }, set: { mode in update(server.id) { $0.mode = mode } }),
                                     identifier: "agent.mcp.\(server.id).mode")
                        .fixedSize()
                    if access.mode == .all {
                        Text("自动包含该服务后续新增的工具。").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(server.tools) { tool in
                                Button { toggleTool(server.id, tool.name) } label: {
                                    HStack(spacing: 8) {
                                        CheckBox(isOn: access.toolNames.contains(tool.name))
                                        Text(tool.displayName).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkMuted.color).lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(tool.summary ?? tool.name)
                                .accessibilityIdentifier("agent.mcp.\(server.id).tool.\(tool.name)")
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.leading, 47) // = 36 + 11, aligned to the name (`.mcp-config`)
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
    }

    /// 「指定工具」 with nothing ticked can call nothing — refused (old app 2026-09-05).
    private var problem: String? {
        for access in draft where access.mode == .selected && access.toolNames.isEmpty {
            return "「\(store.server(access.serverID)?.name ?? access.serverID)」选择了指定工具，但一个也没勾选"
        }
        return nil
    }

    private func setDraft(_ access: [MCPAccess]) {
        state.mcpDrafts[agent.id] = access
    }

    private func toggle(_ server: MCPServerConfig, _ on: Bool) {
        var next = draft.filter { $0.serverID != server.id }
        if on { next.append(MCPAccess(serverID: server.id)) }
        setDraft(next)
    }

    private func update(_ serverID: String, _ change: (inout MCPAccess) -> Void) {
        var next = draft
        guard let index = next.firstIndex(where: { $0.serverID == serverID }) else { return }
        change(&next[index])
        setDraft(next)
    }

    private func toggleTool(_ serverID: String, _ tool: String) {
        update(serverID) { access in
            if let index = access.toolNames.firstIndex(of: tool) { access.toolNames.remove(at: index) } else { access.toolNames.append(tool) }
        }
    }

    private func save() {
        do {
            try state.agents.saveMCP(agent, draft)
            state.mcpDrafts[agent.id] = nil
            state.toasts.show("MCP 配置已保存", note: "新任务将使用这组工具权限")
        } catch {
            state.toasts.show("MCP 配置未保存", note: error.localizedDescription, isError: true)
        }
    }
}
