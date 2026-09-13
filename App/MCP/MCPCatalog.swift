import Foundation

/// The recommended catalog (spec §8.4 layer 1): one click, asking only for what the user must supply.
/// Carried over from the old app (2026-09-07): every endpoint was checked against the vendor's own docs;
/// Google Drive stayed out (it needs a hand-made OAuth client).
struct MCPCatalogEntry: Identifiable, Equatable, Sendable {
    /// A token the user types; it becomes a secret header.
    struct Field: Equatable, Sendable {
        let header: String
        let label: String
        let placeholder: String
        let hint: String
        /// Put before the value on the wire.
        var prefix = "Bearer "
    }

    let id: String
    let name: String
    let summary: String
    let transport: MCPServerConfig.Transport
    /// The browser sign-in works for this service.
    let usesOAuth: Bool
    /// A token as the way in — the only way when OAuth is not offered.
    var field: Field?
    let docs: String
    /// A caveat to read before adding.
    var note: String?

    var mark: String { String(name.prefix(2)).uppercased() }
    var isStdio: Bool { if case .stdio = transport { true } else { false } }
    var tokenIsRequired: Bool { !usesOAuth && field != nil }

    /// The config to store and the secrets for the Keychain. An empty token means the browser sign-in where
    /// the service offers it.
    func config(name: String, token: String) -> (server: MCPServerConfig, secrets: [String: String]) {
        let shown = name.trimmingCharacters(in: .whitespaces)
        var server = MCPServerConfig(id: MCPServerConfig.newID(), name: shown.isEmpty ? self.name : shown,
                                     transport: transport, catalogID: id)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let field, !trimmed.isEmpty {
            server.auth = .header(name: field.header)
            server.secretNames = [field.header]
            return (server, [field.header: field.prefix + trimmed])
        }
        server.auth = usesOAuth ? .oauth : .none
        return (server, [:])
    }

    static func entry(_ id: String) -> MCPCatalogEntry? { all.first { $0.id == id } }

    static let all: [MCPCatalogEntry] = [
        MCPCatalogEntry(id: "linear", name: "Linear", summary: "同步任务、需求与迭代进度",
                        transport: .http(url: "https://mcp.linear.app/mcp"), usesOAuth: true,
                        field: Field(header: "Authorization", label: "Linear API Key（可选）", placeholder: "lin_api_…",
                                     hint: "留空则用浏览器登录 Linear；填了就以这把 Key 的权限访问。"),
                        docs: "https://linear.app/docs/mcp"),
        MCPCatalogEntry(id: "github", name: "GitHub", summary: "读写仓库、Issue 与 Pull Request",
                        transport: .http(url: "https://api.githubcopilot.com/mcp/"), usesOAuth: false,
                        field: Field(header: "Authorization", label: "GitHub 个人访问令牌", placeholder: "ghp_… 或 github_pat_…",
                                     hint: "在 GitHub 的 Developer settings 里生成，保存到 macOS 钥匙串。GitHub 的浏览器登录只对注册过的 App 开放，这里用令牌。"),
                        docs: "https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp-in-your-ide/set-up-the-github-mcp-server"),
        MCPCatalogEntry(id: "notion", name: "Notion", summary: "搜索工作区、读写页面与数据库",
                        transport: .http(url: "https://mcp.notion.com/mcp"), usesOAuth: true,
                        docs: "https://developers.notion.com/guides/mcp/overview"),
        MCPCatalogEntry(id: "figma", name: "Figma", summary: "读取设计稿、Dev Mode 上下文，创建图形",
                        transport: .http(url: "https://mcp.figma.com/mcp"), usesOAuth: true,
                        docs: "https://help.figma.com/hc/en-us/articles/35281350665623",
                        note: "Figma 只认浏览器登录，不收个人访问令牌；它可能只对其目录里的客户端开放注册，登录被拒时属于这条限制。"),
        MCPCatalogEntry(id: "slack", name: "Slack", summary: "搜索消息、读频道、发消息、画布与列表",
                        transport: .http(url: "https://mcp.slack.com/mcp"), usesOAuth: true,
                        docs: "https://docs.slack.dev/ai/slack-mcp-server/"),
        MCPCatalogEntry(id: "sentry", name: "Sentry", summary: "查看线上报错与影响范围",
                        transport: .http(url: "https://mcp.sentry.dev/mcp"), usesOAuth: true,
                        field: Field(header: "Authorization", label: "Sentry 访问令牌（可选）", placeholder: "sntrys_…",
                                     hint: "留空则用浏览器登录；填了就直接用这枚令牌（Sentry-Bearer）。", prefix: "Sentry-Bearer "),
                        docs: "https://github.com/getsentry/sentry-mcp"),
        MCPCatalogEntry(id: "stripe", name: "Stripe", summary: "查询客户、订单、订阅与退款",
                        transport: .http(url: "https://mcp.stripe.com"), usesOAuth: true,
                        field: Field(header: "Authorization", label: "受限 API Key（可选）", placeholder: "rk_…",
                                     hint: "留空则用浏览器登录；Stripe 建议用只带所需权限的受限 Key，先用测试环境的。"),
                        docs: "https://docs.stripe.com/mcp"),
        MCPCatalogEntry(id: "supabase", name: "Supabase", summary: "查询数据库、管理表结构与项目",
                        transport: .http(url: "https://mcp.supabase.com/mcp"), usesOAuth: true,
                        docs: "https://supabase.com/docs/guides/ai-tools/mcp"),
        MCPCatalogEntry(id: "firecrawl", name: "网页抓取（Firecrawl）", summary: "抓取网页正文、爬站、搜索，供 Agent 引用",
                        transport: .http(url: "https://mcp.firecrawl.dev/v2/mcp"), usesOAuth: false,
                        field: Field(header: "Authorization", label: "Firecrawl API Key", placeholder: "fc-…",
                                     hint: "在 firecrawl.dev 的控制台生成，保存到 macOS 钥匙串。"),
                        docs: "https://docs.firecrawl.dev/mcp-server"),
        MCPCatalogEntry(id: "playwright", name: "浏览器操作（Playwright）", summary: "打开网页、点击填表、截图验证",
                        transport: .stdio(command: "npx", args: ["-y", "@playwright/mcp@latest"]), usesOAuth: false,
                        docs: "https://playwright.dev/docs/getting-started-mcp",
                        note: "在本机启动 Node 进程，需要装了 node 与 npx；只有官网版能用。"),
    ]
}
