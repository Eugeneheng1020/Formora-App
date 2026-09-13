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
    /// Said after 「not on its list」 when the service refuses to register Formora — where to go instead.
    var refusedHint: String?
    /// Said instead of the network error when a server on this Mac doesn't answer — how to switch it on.
    var offlineHint: String?

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
        // Figma admits only clients in its MCP catalog (https://www.figma.com/mcp-catalog/); registration answers 403.
        // Kept for when Figma lists Formora — the developer waitlist:
        // https://form.asana.com/?k=kBG-ejRQTdY8x_H6a4vM3Q&d=10497086658021 (user 2026-09-13, D91).
        MCPCatalogEntry(id: "figma", name: "Figma", summary: "读取设计稿、Dev Mode 上下文，创建图形",
                        transport: .http(url: "https://mcp.figma.com/mcp"), usesOAuth: true,
                        docs: "https://help.figma.com/hc/en-us/articles/35281350665623",
                        note: "Figma 只让它 MCP 目录里的应用用浏览器登录，Formora 还不在目录里，所以现在登录不了。有 Figma 付费版的 Dev 或 Full 席位的话，改用「Figma 桌面版」。",
                        refusedHint: "有 Figma 付费版的 Dev 或 Full 席位的话，改用推荐目录里的「Figma 桌面版」"),
        // The Figma app's own server on this Mac: no sign-in and no client list, but a Dev or Full seat on a paid plan.
        MCPCatalogEntry(id: "figma-desktop", name: "Figma 桌面版", summary: "连本机的 Figma 应用：读取选中的图层与设计上下文",
                        transport: .http(url: "http://127.0.0.1:3845/mcp"), usesOAuth: false,
                        docs: "https://developers.figma.com/docs/figma-mcp-server/local-server-installation/",
                        note: "要 Figma 付费版的 Dev 或 Full 席位。先打开 Figma 桌面版和一个设计文件，按 Shift D 切到 Dev Mode，在右侧检查面板的 MCP 一栏点「启用桌面 MCP 服务」。用的时候 Figma 要一直开着。",
                        offlineHint: "连不上 Figma 桌面版：打开 Figma 和一个设计文件，按 Shift D 切到 Dev Mode，在右侧检查面板的 MCP 一栏点「启用桌面 MCP 服务」，再测试连接"),
        // Slack is out (2026-09-13, D91): it offers no client registration, so the browser sign-in can never start.
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
