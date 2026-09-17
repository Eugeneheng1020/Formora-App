import SwiftUI

/// 设置 → MCP (spec §8.4): every configured server, where it connects, how it signs in, its real status,
/// and the global switch — last in the row (spec §4.1).
struct MCPSection: View {
    let state: AppState

    private var store: MCPStore { state.mcp }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .mcp, note: note) {
                Button("添加 MCP 服务") { state.mcpDialog = .add(.catalog) }
                    .buttonStyle(FormoraButtonStyle(kind: .primary))
                    .accessibilityIdentifier("mcp.add")
            }
            if store.servers.isEmpty {
                Text("还没有 MCP 服务，从推荐里挑一个或粘贴配置。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            } else {
                VStack(spacing: 0) {
                    ForEach(store.servers) { server in MCPServerRow(state: state, server: server) }
                }
                .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mcp.list")
            }
        }
    }

    private var note: String {
        let usable = store.servers.filter { store.isUsable($0.id) }.count
        return "\(store.servers.count) 个服务 · \(usable) 个可用"
    }
}

private struct MCPServerRow: View {
    let state: AppState
    let server: MCPServerConfig

    private var store: MCPStore { state.mcp }

    var body: some View {
        let status = store.status(of: server.id)
        let users = store.usage(server.id)
        HStack(alignment: .center, spacing: 11) {
            CapabilityMark(text: server.mark, icon: server.catalogID.flatMap(MCPCatalogEntry.entry)?.logoIcon)
            VStack(alignment: .leading, spacing: 0) {
                Text(server.name).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
                Text("\(server.transportLabel) · \(server.endpointSummary)")
                    .font(FormoraFont.mono(11)).foregroundStyle(Palette.inkMuted.color)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, 2)
                // The mockup's meta row: status first, then the counts and tags.
                HStack(spacing: 6) {
                    MCPStatusLine(status: status).accessibilityIdentifier("mcp.status.\(server.id)")
                    if !server.tools.isEmpty, status.isConnected { SmallTag(text: "\(server.tools.count) 个工具") }
                    if let auth = authTag { SmallTag(text: auth, accent: store.isSignedIn(server.id)) }
                    if !server.plainHeaders.isEmpty || !server.plainEnvironment.isEmpty {
                        SmallTag(text: (server.plainHeaders.merging(server.plainEnvironment) { a, _ in a })
                            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
                    }
                    if users > 0 { SmallTag(text: "\(users) 个 Agent 已启用") }
                }
                .padding(.top, 6)
                if let detail = status.detail, !status.isConnected {
                    Text(detail)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(isProblem(status) ? Palette.alert.color : Palette.inkFaint.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                        .accessibilityIdentifier("mcp.detail.\(server.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if case .needsSignIn = status {
                    Button("浏览器登录") { Task { await store.signIn(server.id) } }
                        .buttonStyle(FormoraButtonStyle())
                        .accessibilityIdentifier("mcp.signIn.\(server.id)")
                } else {
                    Button("测试连接") { Task { await store.test(server.id) } }
                        .buttonStyle(FormoraButtonStyle())
                        .disabled(status == .testing || status == .waitingForBrowser || status == .unsupported || !server.isEnabled)
                        .accessibilityIdentifier("mcp.test.\(server.id)")
                }
                IconActionButton(icon: Icons.settings, label: "编辑 \(server.name)", identifier: "mcp.edit.\(server.id)") {
                    state.mcpDialog = .edit(server.id)
                }
                IconActionButton(icon: Icons.trash, label: users > 0 ? MCPProblem.inUse(users).message : "删除 \(server.name)",
                                 identifier: "mcp.delete.\(server.id)") { delete() }
                    .disabled(users > 0)
                FormoraSwitch(isOn: Binding(get: { server.isEnabled }, set: { store.setEnabled(server.id, $0) }),
                              label: "启用 \(server.name)", identifier: "mcp.enabled.\(server.id)")
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp.row.\(server.id)")
    }

    private var authTag: String? {
        switch server.auth {
        case .none: nil
        case .header: "令牌"
        case .oauth: store.isSignedIn(server.id) ? "已登录" : "浏览器登录"
        }
    }

    private func isProblem(_ status: MCPStore.Status) -> Bool {
        switch status {
        case .failed, .needsSignIn: true
        default: false
        }
    }

    /// Re-adding is a few fields, so no confirmation (spec §8.7 rule 3); the toast says what went.
    private func delete() {
        do {
            try store.delete(server.id)
            state.toasts.show("已删除「\(server.name)」")
        } catch {
            state.toasts.show("没有删除", note: (error as? MCPProblem)?.message ?? error.localizedDescription, isError: true)
        }
    }
}

/// `.status-line` for MCP: connected green, problems alert, configured ink, in progress accent.
struct MCPStatusLine: View {
    let status: MCPStore.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.label).font(FormoraFont.ui(10.5)).foregroundStyle(color)
        }
        .fixedSize()
    }

    private var color: Color {
        switch status {
        case .connected: Palette.success.color
        case .failed, .needsSignIn: Palette.alert.color
        case .testing, .waitingForBrowser: Palette.accent.color
        case .configured: Palette.ink.color
        case .unsupported, .disabled: Palette.inkFaint.color
        }
    }
}
