/// Line icons. Copied verbatim from `docs/design/main-view-v4.html` / `launch-flow-v1.html` unless noted.
enum Icons {
    static let messages = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>"#, name: "messages")

    static let agents = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="4"/><circle cx="9" cy="10" r="1.4" fill="currentColor" stroke="none"/><circle cx="15" cy="10" r="1.4" fill="currentColor" stroke="none"/><path d="M8.5 14.5c1 1 2 1.4 3.5 1.4s2.5-.4 3.5-1.4"/></svg>"#, name: "agents")

    static let board = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16M15 4v16"/></svg>"#, name: "board")

    static let files = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z"/></svg>"#, name: "files")

    /// 配置 (user 2026-09-16): sliders, the "adjust these" affordance — not the app-settings gear.
    static let sliders = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="8" x2="20" y2="8"/><circle cx="9" cy="8" r="2.4"/><line x1="4" y1="16" x2="20" y2="16"/><circle cx="15" cy="16" r="2.4"/></svg>"#, name: "sliders")
    static let settings = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>"#, name: "settings")

    static let file = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></svg>"#, name: "file")

    static let chevronUpDown = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m7 15 5 5 5-5M7 9l5-5 5 5"/></svg>"#, name: "chevronUpDown")

    static let chevronRight = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 6 6 6-6 6"/></svg>"#, name: "chevronRight")

    static let chevronLeft = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m15 6-6 6 6 6"/></svg>"#, name: "chevronLeft")

    static let plus = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>"#, name: "plus")

    static let search = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.35-4.35"/></svg>"#, name: "search")

    static let check = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>"#, name: "check")

    static let close = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>"#, name: "close")

    static let trash = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v5M14 11v5"/></svg>"#, name: "trash")

    static let pencil = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/></svg>"#, name: "pencil")

    /// Not in the mockup: 复制 (user 2026-09-14), two sheets in the same line style.
    static let copy = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10 8h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2V10a2 2 0 0 1 2-2z"/><path d="M4 16a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2"/></svg>"#, name: "copy")

    /// Not in the mockup: "show in Finder", drawn in the same line style (arrow out of a box).
    static let reveal = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h6v6"/><path d="M20 4l-9 9"/><path d="M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/></svg>"#, name: "reveal")

    /// Not in the mockup: the error mark for failure toasts (circle + exclamation), same line style.
    static let alertCircle = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 8v5"/><path d="M12 16.5h.01"/></svg>"#, name: "alertCircle")

    /// 设置 → 账户 (mockup `settingsCategories`).
    static let person = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8.5" r="3.5"/><path d="M5 20c0-3.6 3.1-6 7-6s7 2.4 7 6"/></svg>"#, name: "person")

    /// 设置 → 模型 (mockup `settingsCategories`).
    static let chip = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="7" width="10" height="10" rx="2.5"/><path d="M10 4v3M14 4v3M10 17v3M14 17v3M4 10h3M4 14h3M17 10h3M17 14h3"/></svg>"#, name: "chip")

    /// The bash tool's card (7c): a prompt.
    static let terminal = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 17l6-5-6-5"/><path d="M12 19h8"/></svg>"#, name: "terminal")

    /// 设置 → Hooks (7b′): a bolt — something that fires on its own at a moment.
    /// 设置 → Hooks: a webhook (user 2026-09-12: the lightning bolt didn't read as a hook).
    static let hook = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M18 16.98h-5.99c-1.1 0-1.95.94-2.48 1.9A4 4 0 0 1 2 17c.01-.7.2-1.4.57-2"/><path d="m6 17 3.13-5.78c.53-.97.1-2.18-.5-3.1a4 4 0 1 1 6.89-4.06"/><path d="m12 6 3.13 5.73C15.66 12.7 16.9 13 18 13a4 4 0 0 1 0 8"/></svg>"#, name: "hook")

    /// The avatar upload button (mockup `.avatar-upload-btn`).
    static let upload = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 16V4M7 9l5-5 5 5"/><path d="M5 14v5h14v-5"/></svg>"#, name: "upload")

    /// Not in the mockup: show / hide a saved API key (user 2026-09-05), same line style.
    static let eye = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></svg>"#, name: "eye")

    static let eyeOff = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3l18 18"/><path d="M10.6 5.1A10.7 10.7 0 0 1 12 5c6.4 0 10 7 10 7a17.6 17.6 0 0 1-3.2 4.2M6.6 6.6C3.8 8.4 2 12 2 12s3.6 7 10 7a9.9 9.9 0 0 0 5.4-1.6"/><path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>"#, name: "eyeOff")

    /// Not in the mockup: refresh a provider's model list (todo #4), same line style.
    static let refresh = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 11a8 8 0 0 0-14.9-3.9L4 8.5"/><path d="M4 4v4.5h4.5"/><path d="M4 13a8 8 0 0 0 14.9 3.9l1.1-1.4"/><path d="M20 20v-4.5h-4.5"/></svg>"#, name: "refresh")

    /// Not in the mockup: 停用 / 激活 in an Agent's context menu (old app D64) — one glyph for the switch,
    /// the menu's words say which way it goes.
    static let power = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v8"/><path d="M6.4 6.4a8 8 0 1 0 11.2 0"/></svg>"#, name: "power")

    /// 设置 → Skills (mockup `settingsCategories`).
    static let sparkle = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 4.2 12 8.4l4.2 1.5-4.2 1.5-1.5 4.2L9 11.4 4.8 9.9 9 8.4l1.5-4.2Z"/><path d="M17.3 14.6l.6 1.8 1.8.6-1.8.6-.6 1.8-.6-1.8-1.8-.6 1.8-.6.6-1.8Z"/></svg>"#, name: "sparkle")

    /// 设置 → Bob (7h, B1; old app 2026-09-09: a robot).
    /// 子代理 (user 2026-09-16): a parent node budding two helpers — the spawn/delegate motif, with a spark on the parent.
    static let subagents = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="5" r="2.6"/><circle cx="5" cy="19" r="2.6"/><circle cx="19" cy="19" r="2.6"/><path d="M12 7.6v3.2a2 2 0 0 1-2 2H7a2 2 0 0 0-2 2v1.6"/><path d="M12 10.8a2 2 0 0 0 2 2h3a2 2 0 0 1 2 2v1.6"/><path d="M12 2.2v1.1M10.4 3l.8.7M13.6 3l-.8.7"/></svg>"#, name: "subagents")
    static let robot = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 8V4H8"/><rect width="16" height="12" x="4" y="8" rx="2"/><path d="M2 14h2M20 14h2M15 13v2M9 13v2"/></svg>"#, name: "robot")

    /// 设置 → MCP (mockup `settingsCategories`).
    static let plug = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3v6M15 3v6"/><path d="M6.5 9h11v2.4a5.5 5.5 0 0 1-11 0V9Z"/><path d="M12 16.9V21"/></svg>"#, name: "plug")

    /// The composer's 添加文件 (mockup `composerAttachBtn`).
    static let paperclip = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21.4 11.1 12.3 20a5 5 0 0 1-7-7l9-9a3.3 3.3 0 1 1 4.7 4.7l-9 9a1.7 1.7 0 0 1-2.4-2.4l8.3-8.3"/></svg>"#, name: "paperclip")

    /// The send button (mockup `.send-btn`, stroke 2).
    static let send = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg>"#, name: "send")

    /// The reasoning pill (mockup `.reasoning-btn`).
    static let bulb = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3a6 6 0 0 0-3.6 10.8c.6.5.9 1.1.9 1.8v.4h5.4v-.4c0-.7.3-1.3.9-1.8A6 6 0 0 0 12 3Z"/><path d="M10 20h4"/></svg>"#, name: "bulb")

    /// 设置 → 归档 and 归档会话 (mockup `settingsCategories`, `openContextMenu`).
    static let archive = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v11a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V8"/><path d="M10 12h4"/></svg>"#, name: "archive")

    /// 去 Agent 的详情 (mockup `openContextMenu`).
    static let arrowUpRight = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17 17 7"/><path d="M9 7h8v8"/></svg>"#, name: "arrowUpRight")

    /// A group without members, and 群设置 (mockup `convAvatarHtml`).
    static let users = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M16 19v-1.5a3.5 3.5 0 0 0-3.5-3.5h-5A3.5 3.5 0 0 0 4 17.5V19"/><circle cx="10" cy="8" r="3"/><path d="M20 19v-1.5a3.5 3.5 0 0 0-2.6-3.4"/><path d="M15.5 5.2a3 3 0 0 1 0 5.6"/></svg>"#, name: "users")

    /// An image attachment without a thumbnail.
    static let image = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21"/></svg>"#, name: "image")

    /// 设置 → 通知 (mockup `settingsCategories`; its `S` segment written out as `C`).
    static let bell = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8.6a6 6 0 1 0-12 0c0 5.4-2.1 6.9-2.1 6.9h16.2C20.1 15.5 18 14 18 8.6Z"/><path d="M13.7 19a2 2 0 0 1-3.4 0"/></svg>"#, name: "bell")

    /// 设置 → 用量 (2026-09-14): three bars.
    static let chart = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h16"/><path d="M7 16v-5"/><path d="M12 16V7"/><path d="M17 16v-8"/></svg>"#, name: "chart")

    /// 设置 → 关于 (2026-09-14): an i in a circle.
    static let info = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v5"/><path d="M12 8h.01"/></svg>"#, name: "info")

    /// 设置 → 电脑操作 (7j, B2): a display.
    static let display = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="19" height="13" rx="2"/><path d="M8 20.5h8M12 16.5v4"/></svg>"#, name: "display")

    /// 看板's view controls (8b, K7): back to the auto layout, and back to the content.
    static let relayout = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/></svg>"#, name: "relayout")
    static let recenter = SVGIcon(validated: #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12h3M19 12h3M12 2v3M12 19v3"/><circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="2.5"/></svg>"#, name: "recenter")

    static let all: [(String, SVGIcon)] = [("robot", robot), ("display", display), ("relayout", relayout), ("recenter", recenter), 
        ("bell", bell), ("paperclip", paperclip), ("send", send), ("bulb", bulb), ("archive", archive), ("arrowUpRight", arrowUpRight),
        ("users", users), ("image", image),
        ("power", power), ("sparkle", sparkle), ("plug", plug),
        ("messages", messages), ("agents", agents), ("board", board), ("files", files), ("file", file), ("settings", settings),
        ("chevronUpDown", chevronUpDown), ("chevronRight", chevronRight), ("chevronLeft", chevronLeft),
        ("plus", plus), ("search", search), ("check", check), ("close", close), ("trash", trash),
        ("pencil", pencil), ("reveal", reveal), ("alertCircle", alertCircle),
        ("person", person), ("chip", chip), ("upload", upload), ("eye", eye), ("eyeOff", eyeOff), ("refresh", refresh),
    ]
}
