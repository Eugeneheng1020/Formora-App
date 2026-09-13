import Foundation

/// The recommended catalog (spec §8.4 layer 1): one click, asking only for what the user must supply.
/// Carried over from the old app (2026-09-07); Google Drive stayed out (it needs a hand-made OAuth client). D94 (user
/// 2026-09-13): thirty services in five groups. Every one that signs in was checked the day it went in — each accepted
/// Formora's client registration — and every local server is pinned to the version that started and listed its tools
/// that day (it may hold a token or read a folder, so an unchecked update doesn't run).
struct MCPCatalogEntry: Identifiable, Equatable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case office, design, dev, research, business

        var title: String {
            switch self {
            case .office: "办公协作"
            case .design: "设计"
            case .dev: "开发部署"
            case .research: "查资料"
            case .business: "商务"
            }
        }
    }

    /// Something the user supplies (D94: an entry may ask for several).
    struct Field: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Kept in the Keychain: a request header (HTTP) or a local server's environment variable; `prefix` goes first.
            case secret(name: String, prefix: String)
            /// Not a secret: a local server's environment variable, kept in its config.
            case environment(name: String)
            /// A folder on this Mac, put into the command where `{folder}` stands; a right one contains `mustContain`.
            case folder(mustContain: String?)
        }

        let id: String
        let kind: Kind
        let label: String
        let placeholder: String
        let hint: String

        var isSecret: Bool { if case .secret = kind { true } else { false } }
        var isFolder: Bool { if case .folder = kind { true } else { false } }

        static func secret(_ id: String = "token", name: String, label: String, placeholder: String, hint: String,
                           prefix: String = "Bearer ") -> Field {
            Field(id: id, kind: .secret(name: name, prefix: prefix), label: label, placeholder: placeholder, hint: hint)
        }

        static func environment(_ id: String, name: String, label: String, placeholder: String, hint: String) -> Field {
            Field(id: id, kind: .environment(name: name), label: label, placeholder: placeholder, hint: hint)
        }

        static func folder(_ id: String = "folder", label: String, placeholder: String, hint: String, mustContain: String? = nil) -> Field {
            Field(id: id, kind: .folder(mustContain: mustContain), label: label, placeholder: placeholder, hint: hint)
        }
    }

    /// Where a folder goes in a local server's arguments.
    static let folderSlot = "{folder}"

    let id: String
    let name: String
    let summary: String
    let category: Category
    let transport: MCPServerConfig.Transport
    /// The browser sign-in works for this service.
    let usesOAuth: Bool
    /// What the user fills in. A secret is optional where the browser sign-in works too; a folder never is.
    var fields: [Field] = []
    let docs: String
    /// A caveat to read before adding.
    var note: String?
    /// Said instead of the network error when a server on this Mac doesn't answer — how to switch it on.
    var offlineHint: String?
    /// Non-secret environment variables a local (stdio) server starts with.
    var environment: [String: String] = [:]
    /// A file in `Resources/ProviderLogos` (simple-icons, CC0; D94); `nil` shows `mark`.
    var logo: String?

    var mark: String { String(name.prefix(2)).uppercased() }
    var isStdio: Bool { if case .stdio = transport { true } else { false } }
    var tokenIsRequired: Bool { !usesOAuth && fields.contains(where: \.isSecret) }
    var logoIcon: SVGIcon? { logo.flatMap(ProviderLogos.icon) }

    /// The first field left empty that has to be filled: a folder always, anything else unless the browser sign-in works.
    func missing(_ values: [String: String]) -> Field? {
        fields.first { field in
            guard (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return field.isFolder || !usesOAuth
        }
    }

    /// A folder that isn't one on this Mac, or not the right one (Obsidian's vault has `.obsidian`).
    func folderProblem(_ values: [String: String]) -> String? {
        for field in fields {
            guard case .folder(let mustContain) = field.kind else { continue }
            let path = Self.folderPath(values[field.id] ?? "")
            guard !path.isEmpty else { continue }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                return "「\(path)」不是这台 Mac 上的文件夹"
            }
            if let mustContain, !FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(mustContain)) {
                return "这个文件夹里没有 \(mustContain)，不像 \(name) 要的那个；要选它的根文件夹"
            }
        }
        return nil
    }

    /// `~` expanded, no trailing slash.
    static func folderPath(_ raw: String) -> String {
        var path = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// With the token as the entry's first secret.
    func config(name: String, token: String) -> (server: MCPServerConfig, secrets: [String: String]) {
        config(name: name, values: fields.first(where: \.isSecret).map { [$0.id: token] } ?? [:])
    }

    /// The config to store and the secrets for the Keychain. With no secret given, the browser sign-in where the service
    /// offers it.
    func config(name: String, values: [String: String]) -> (server: MCPServerConfig, secrets: [String: String]) {
        var environment = self.environment
        var secrets: [String: String] = [:]
        var firstSecret: String?
        var folder = ""
        for field in fields {
            let value = (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch field.kind {
            case .secret(let key, let prefix):
                secrets[key] = prefix + value
                if firstSecret == nil { firstSecret = key }
            case .environment(let key):
                environment[key] = value
            case .folder:
                folder = Self.folderPath(value)
            }
        }
        var transport = self.transport
        if case .stdio(let command, let args) = transport {
            transport = .stdio(command: command, args: args.map { $0.replacingOccurrences(of: Self.folderSlot, with: folder) })
        }
        let shown = name.trimmingCharacters(in: .whitespaces)
        var server = MCPServerConfig(id: MCPServerConfig.newID(), name: shown.isEmpty ? self.name : shown, transport: transport,
                                     plainEnvironment: environment, catalogID: id)
        if let firstSecret {
            server.auth = .header(name: firstSecret)
            server.secretNames = secrets.keys.sorted()
        } else {
            server.auth = usesOAuth ? .oauth : .none
        }
        return (server, secrets)
    }

    static func entry(_ id: String) -> MCPCatalogEntry? { all.first { $0.id == id } }

    static let all: [MCPCatalogEntry] = [
        // MARK: 办公协作
        MCPCatalogEntry(id: "linear", name: "Linear", summary: "同步任务、需求与迭代进度", category: .office,
                        transport: .http(url: "https://mcp.linear.app/mcp"), usesOAuth: true,
                        fields: [.secret(name: "Authorization", label: "Linear API Key（可选）", placeholder: "lin_api_…",
                                         hint: "留空则用浏览器登录 Linear；填了就以这把 Key 的权限访问。")],
                        docs: "https://linear.app/docs/mcp", logo: "linear"),
        MCPCatalogEntry(id: "notion", name: "Notion", summary: "搜索工作区、读写页面与数据库", category: .office,
                        transport: .http(url: "https://mcp.notion.com/mcp"), usesOAuth: true,
                        docs: "https://developers.notion.com/guides/mcp/overview", logo: "notion"),
        MCPCatalogEntry(id: "notion-token", name: "Notion（令牌）", summary: "用集成令牌读写页面与数据库", category: .office,
                        transport: .stdio(command: "npx", args: ["-y", "@notionhq/notion-mcp-server@2.5.1"]), usesOAuth: false,
                        fields: [.secret(name: "NOTION_TOKEN", label: "Notion 集成令牌", placeholder: "ntn_…",
                                         hint: "在 Notion 的「设置 → 集成」里新建一个内部集成，复制它的令牌；保存到 macOS 钥匙串。", prefix: "")],
                        docs: "https://github.com/makenotion/notion-mcp-server",
                        note: "Notion 官方出的本机服务：要用的页面先分享给这个集成，它才看得到。浏览器登录的「Notion」也能用，这个是备选。在本机用 npx 启动，只有官网版能用。",
                        logo: "notion"),
        MCPCatalogEntry(id: "atlassian", name: "Atlassian", summary: "Jira 任务与 Confluence 文档", category: .office,
                        transport: .http(url: "https://mcp.atlassian.com/v1/mcp"), usesOAuth: true,
                        docs: "https://support.atlassian.com/rovo/docs/getting-started-with-the-atlassian-remote-mcp-server/", logo: "atlassian"),
        MCPCatalogEntry(id: "asana", name: "Asana", summary: "任务、项目与进度", category: .office,
                        transport: .http(url: "https://mcp.asana.com/mcp"), usesOAuth: true,
                        docs: "https://developers.asana.com/docs/using-asanas-mcp-server", logo: "asana"),
        MCPCatalogEntry(id: "monday", name: "monday.com", summary: "看板、任务与团队工作流", category: .office,
                        transport: .http(url: "https://mcp.monday.com/mcp"), usesOAuth: true,
                        docs: "https://monday.com"),
        MCPCatalogEntry(id: "todoist", name: "Todoist", summary: "待办事项、项目与提醒", category: .office,
                        transport: .http(url: "https://ai.todoist.net/mcp"), usesOAuth: true,
                        docs: "https://www.todoist.com", logo: "todoist"),
        // 飞书's server reads APP_ID and APP_SECRET from its environment (dist/utils/constants.js, 0.5.1), so the secret stays
        // in the Keychain and out of the command line.
        MCPCatalogEntry(id: "feishu", name: "飞书", summary: "文档、多维表格、消息与日历", category: .office,
                        transport: .stdio(command: "npx", args: ["-y", "@larksuiteoapi/lark-mcp@0.5.1", "mcp"]), usesOAuth: false,
                        fields: [.environment("app_id", name: "APP_ID", label: "App ID", placeholder: "cli_…",
                                              hint: "在飞书开放平台建一个企业自建应用，在「凭证与基础信息」里找到。"),
                                 .secret("app_secret", name: "APP_SECRET", label: "App Secret", placeholder: "应用的 App Secret",
                                         hint: "同一页里；保存到 macOS 钥匙串。在对话里给 Bob 时写成「App Secret：…」。", prefix: "")],
                        docs: "https://github.com/larksuite/lark-openapi-mcp",
                        note: "飞书官方出的本机服务，以应用身份调用飞书开放平台：要在开放平台给这个应用开通用到的权限。在本机用 npx 启动，只有官网版能用。"),
        MCPCatalogEntry(id: "obsidian", name: "Obsidian", summary: "读写笔记库里的笔记、标签与属性", category: .office,
                        transport: .stdio(command: "npx", args: ["-y", "obsidian-mcp@2.0.1", "serve", "--vault", "notes=\(folderSlot)"]),
                        usesOAuth: false,
                        fields: [.folder(label: "笔记库文件夹", placeholder: "/Users/你/Documents/笔记库",
                                         hint: "选笔记库的根文件夹（里面有 .obsidian 的那个）。", mustContain: ".obsidian")],
                        docs: "https://www.npmjs.com/package/obsidian-mcp",
                        note: "开源社区的本机服务（obsidian-mcp，不是 Obsidian 官方出的），直接读写笔记库里的 Markdown 文件，Obsidian 不用开着；它会在笔记库里建一个 .obsidian-mcp 文件夹放自己的工作文件（锁、回收站等）。要 Node 22 或更新，只有官网版能用。",
                        logo: "obsidian"),

        // MARK: 设计
        // Figma with a token (user 2026-09-13, D92). Figma's own server (https://mcp.figma.com/mcp) admits only clients in
        // its MCP catalog — registration answers 403, a personal access token gets 401 — so Framelink, open source (MIT,
        // github.com/GLips/Figma-Context-MCP), reads designs through the REST API with the user's token. For when Formora is
        // listed, Figma's developer waitlist: https://form.asana.com/?k=kBG-ejRQTdY8x_H6a4vM3Q&d=10497086658021
        MCPCatalogEntry(id: "figma-token", name: "Figma", summary: "读取设计稿的图层、样式与文字，导出切图", category: .design,
                        transport: .stdio(command: "npx", args: ["-y", "figma-developer-mcp@0.13.2", "--stdio"]), usesOAuth: false,
                        fields: [.secret(name: "FIGMA_API_KEY", label: "Figma 个人访问令牌", placeholder: "figd_…",
                                         hint: "在 Figma 的「设置 → 安全 → 个人访问令牌」里生成，至少勾选读取文件内容（file_content:read），保存到 macOS 钥匙串。",
                                         prefix: "")],
                        docs: "https://github.com/GLips/Figma-Context-MCP",
                        note: "用开源的 Framelink 服务（不是 Figma 官方出的）拿你的令牌读取设计稿：只读，不改画布。它在本机用 npx 启动，要装了 node；第一次启动要下载，最长等 60 秒。只有官网版能用。它的使用数据统计已关掉。",
                        environment: ["FRAMELINK_TELEMETRY": "off"], logo: "figma"),
        // The Figma app's own server on this Mac: no sign-in and no client list, but a Dev or Full seat on a paid plan.
        MCPCatalogEntry(id: "figma-desktop", name: "Figma 桌面版", summary: "连本机的 Figma 应用：读取选中的图层与设计上下文", category: .design,
                        transport: .http(url: "http://127.0.0.1:3845/mcp"), usesOAuth: false,
                        docs: "https://developers.figma.com/docs/figma-mcp-server/local-server-installation/",
                        note: "要 Figma 付费版的 Dev 或 Full 席位。先打开 Figma 桌面版和一个设计文件，按 Shift D 切到 Dev Mode，在右侧检查面板的 MCP 一栏点「启用桌面 MCP 服务」。用的时候 Figma 要一直开着。",
                        offlineHint: "连不上 Figma 桌面版：打开 Figma 和一个设计文件，按 Shift D 切到 Dev Mode，在右侧检查面板的 MCP 一栏点「启用桌面 MCP 服务」，再测试连接",
                        logo: "figma"),
        MCPCatalogEntry(id: "canva", name: "Canva", summary: "生成、查找与编辑设计", category: .design,
                        transport: .http(url: "https://mcp.canva.com/mcp"), usesOAuth: true,
                        docs: "https://www.canva.dev/docs/mcp/", logo: "canva"),

        // MARK: 开发部署
        MCPCatalogEntry(id: "github", name: "GitHub", summary: "读写仓库、Issue 与 Pull Request", category: .dev,
                        transport: .http(url: "https://api.githubcopilot.com/mcp/"), usesOAuth: false,
                        fields: [.secret(name: "Authorization", label: "GitHub 个人访问令牌", placeholder: "ghp_… 或 github_pat_…",
                                         hint: "在 GitHub 的 Developer settings 里生成，保存到 macOS 钥匙串。GitHub 的浏览器登录只对注册过的 App 开放，这里用令牌。")],
                        docs: "https://docs.github.com/en/copilot/how-tos/provide-context/use-mcp-in-your-ide/set-up-the-github-mcp-server",
                        logo: "github"),
        MCPCatalogEntry(id: "gitlab", name: "GitLab", summary: "仓库、Issue 与合并请求（gitlab.com）", category: .dev,
                        transport: .http(url: "https://gitlab.com/api/v4/mcp"), usesOAuth: true,
                        docs: "https://docs.gitlab.com/user/gitlab_duo/model_context_protocol/mcp_server/", logo: "gitlab"),
        // Slack is out (2026-09-13, D91): it offers no client registration, so the browser sign-in can never start. So is
        // Box (D94), for the same reason.
        MCPCatalogEntry(id: "sentry", name: "Sentry", summary: "查看线上报错与影响范围", category: .dev,
                        transport: .http(url: "https://mcp.sentry.dev/mcp"), usesOAuth: true,
                        fields: [.secret(name: "Authorization", label: "Sentry 访问令牌（可选）", placeholder: "sntrys_…",
                                         hint: "留空则用浏览器登录；填了就直接用这枚令牌（Sentry-Bearer）。", prefix: "Sentry-Bearer ")],
                        docs: "https://github.com/getsentry/sentry-mcp", logo: "sentry"),
        MCPCatalogEntry(id: "vercel", name: "Vercel", summary: "项目、部署与日志", category: .dev,
                        transport: .http(url: "https://mcp.vercel.com"), usesOAuth: true,
                        docs: "https://vercel.com/docs/mcp/vercel-mcp", logo: "vercel"),
        MCPCatalogEntry(id: "neon", name: "Neon", summary: "Postgres 数据库、分支与查询", category: .dev,
                        transport: .http(url: "https://mcp.neon.tech/mcp"), usesOAuth: true,
                        docs: "https://neon.com/docs/ai/neon-mcp-server", logo: "neon"),
        MCPCatalogEntry(id: "supabase", name: "Supabase", summary: "查询数据库、管理表结构与项目", category: .dev,
                        transport: .http(url: "https://mcp.supabase.com/mcp"), usesOAuth: true,
                        docs: "https://supabase.com/docs/guides/ai-tools/mcp", logo: "supabase"),
        MCPCatalogEntry(id: "huggingface", name: "Hugging Face", summary: "搜索模型、数据集、论文与 Space", category: .dev,
                        transport: .http(url: "https://huggingface.co/mcp"), usesOAuth: false,
                        docs: "https://huggingface.co/settings/mcp", logo: "huggingface"),
        MCPCatalogEntry(id: "chrome-devtools", name: "Chrome 开发者工具", summary: "打开 Chrome 调试网页、看报错、测性能", category: .dev,
                        transport: .stdio(command: "npx", args: ["-y", "chrome-devtools-mcp@1.9.0"]), usesOAuth: false,
                        docs: "https://github.com/ChromeDevTools/chrome-devtools-mcp",
                        note: "Google 出的本机服务，要装了 Chrome；用到浏览器时它会自己开一个 Chrome。在本机用 npx 启动，只有官网版能用。",
                        logo: "googlechrome"),
        MCPCatalogEntry(id: "playwright", name: "浏览器操作（Playwright）", summary: "打开网页、点击填表、截图验证", category: .dev,
                        transport: .stdio(command: "npx", args: ["-y", "@playwright/mcp@0.0.80"]), usesOAuth: false,
                        docs: "https://playwright.dev/docs/getting-started-mcp",
                        note: "在本机启动 Node 进程，需要装了 node 与 npx；只有官网版能用。", logo: "playwright"),
        MCPCatalogEntry(id: "filesystem", name: "文件系统", summary: "读写你指定的一个文件夹", category: .dev,
                        transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem@2026.8.31", folderSlot]),
                        usesOAuth: false,
                        fields: [.folder(label: "允许读写的文件夹", placeholder: "/Users/你/Documents/资料",
                                         hint: "Agent 只能读写这个文件夹里的东西。")],
                        docs: "https://github.com/modelcontextprotocol/servers/tree/main/src/filesystem",
                        note: "MCP 官方的参考实现，在本机启动，只能读写你选的这个文件夹。Formora 的 Agent 本来就能读写当前项目，这个用来再给它一个文件夹。只有官网版能用。"),

        // MARK: 查资料
        MCPCatalogEntry(id: "context7", name: "Context7", summary: "查各种编程库的最新文档与示例", category: .research,
                        transport: .http(url: "https://mcp.context7.com/mcp"), usesOAuth: false, docs: "https://context7.com"),
        MCPCatalogEntry(id: "deepwiki", name: "DeepWiki", summary: "读懂 GitHub 上的开源项目", category: .research,
                        transport: .http(url: "https://mcp.deepwiki.com/mcp"), usesOAuth: false, docs: "https://deepwiki.com"),
        MCPCatalogEntry(id: "cloudflare-docs", name: "Cloudflare 文档", summary: "查 Cloudflare 各产品的文档", category: .research,
                        transport: .http(url: "https://docs.mcp.cloudflare.com/mcp"), usesOAuth: false,
                        docs: "https://developers.cloudflare.com/agents/model-context-protocol/", logo: "cloudflare"),
        MCPCatalogEntry(id: "firecrawl", name: "网页抓取（Firecrawl）", summary: "抓取网页正文、爬站、搜索，供 Agent 引用", category: .research,
                        transport: .http(url: "https://mcp.firecrawl.dev/v2/mcp"), usesOAuth: false,
                        fields: [.secret(name: "Authorization", label: "Firecrawl API Key", placeholder: "fc-…",
                                         hint: "在 firecrawl.dev 的控制台生成，保存到 macOS 钥匙串。")],
                        docs: "https://docs.firecrawl.dev/mcp-server"),

        // MARK: 商务
        MCPCatalogEntry(id: "stripe", name: "Stripe", summary: "查询客户、订单、订阅与退款", category: .business,
                        transport: .http(url: "https://mcp.stripe.com"), usesOAuth: true,
                        fields: [.secret(name: "Authorization", label: "受限 API Key（可选）", placeholder: "rk_…",
                                         hint: "留空则用浏览器登录；Stripe 建议用只带所需权限的受限 Key，先用测试环境的。")],
                        docs: "https://docs.stripe.com/mcp", logo: "stripe"),
        MCPCatalogEntry(id: "paypal", name: "PayPal", summary: "订单、发票与交易", category: .business,
                        transport: .http(url: "https://mcp.paypal.com/mcp"), usesOAuth: true,
                        docs: "https://developer.paypal.com", logo: "paypal"),
        MCPCatalogEntry(id: "intercom", name: "Intercom", summary: "客服对话、用户与工单", category: .business,
                        transport: .http(url: "https://mcp.intercom.com/mcp"), usesOAuth: true,
                        docs: "https://developers.intercom.com", logo: "intercom"),
        MCPCatalogEntry(id: "wix", name: "Wix", summary: "网站、商品、订单与预约", category: .business,
                        transport: .http(url: "https://mcp.wix.com/mcp"), usesOAuth: true,
                        docs: "https://dev.wix.com", logo: "wix"),
    ]
}
