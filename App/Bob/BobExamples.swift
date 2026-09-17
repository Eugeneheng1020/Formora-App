import Foundation

/// What to ask Bob and how he answers it (user 2026-09-13): the hand of cards on 设置 → Bob, and the list his panel
/// offers while empty. The answers are written ahead from what he really does under 每次询问 — not asked of a model,
/// so they cost nothing and show without one — and each card says 示例回答.
struct BobExample: Identifiable, Sendable {
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case howTo, status, settings, work

        var id: String { rawValue }

        var title: String {
            switch self {
            case .howTo: "问 Formora 怎么用"
            case .status: "查现在的情况"
            case .settings: "替你改设置"
            case .work: "动手做事"
            }
        }
    }

    /// One of his steps as his panel shows it, finished.
    struct Step: Sendable {
        enum Kind: Sendable {
            case read, search, skill, plug, bell, write, terminal, computer
        }

        let kind: Kind
        let summary: String
        var status = "完成"
        /// It waited for 允许, and got it.
        var allowed = false
    }

    /// The card under a step that changed something, as `BobResult` shows it.
    struct Result: Sendable {
        let title: String
        let meta: String
    }

    let id: Int
    let group: Group
    let question: String
    /// A file that goes with the question: 问 Bob then leaves the question in his input, for the file to be added.
    var attachment: String?
    let answer: String
    var steps: [Step] = []
    var result: Result?
    /// What the example needs that isn't on by default.
    var needs: String?
}

enum BobExamples {
    static let all: [BobExample] = [
        BobExample(id: 1, group: .howTo, question: "/compact 是干什么用的？",
                   answer: "/compact 把前面的对话整理成一段摘要，原文折叠保留，不会删掉。上下文快满时（输入框右下角的圆环变红）用它腾出地方；也可以写上一定要留下的重点，比如「/compact 保留接口约定」。",
                   steps: [.init(kind: .read, summary: "读说明 · 输入框里的指令")]),
        BobExample(id: 2, group: .howTo, question: "群聊里不 @ 人，消息会交给谁？",
                   answer: "会按任务性质分给一个成员：同一个岗位里挑空闲的，接着谁的活就交给谁，对话里写一行「分配给 X：理由」。给我配了模型的话，由我来安排谁先做、谁同时做。",
                   steps: [.init(kind: .read, summary: "读说明 · Agent 与协作")]),
        BobExample(id: 3, group: .status, question: "Formora 都有哪些 Agent？",
                   answer: "现在有 3 个：产品设计（小设）、研发（前端）、测试（验收）。研发（前端）正在做「会员体系」的接口，另外两个空闲。",
                   steps: [.init(kind: .search, summary: "查看现状 · agents")]),
        BobExample(id: 4, group: .status, question: "当前项目的任务都做到哪了？",
                   answer: "「会员体系专项」里 3 件事做完了 2 件；测试（验收）那一件停在一步写文件上，等你确认。",
                   steps: [.init(kind: .search, summary: "查看现状 · tasks")]),
        BobExample(id: 5, group: .settings, question: "帮我建一个叫「验收标准检查」的 Skill",
                   answer: "建好了，放进了全局 Skills 库，没有替任何 Agent 启用。要用的话，去那个 Agent 的 Skills 标签里打开。",
                   steps: [.init(kind: .skill, summary: "新建 Skill「验收标准检查」", allowed: true)],
                   result: .init(title: "已创建 Skill「验收标准检查」", meta: "全局 Skills 库 · 还没有 Agent 启用")),
        BobExample(id: 6, group: .settings, question: "接入 Notion",
                   answer: "接好了。Notion 要在浏览器里登录，我接入时已经打开了浏览器，你登录完回到 Formora 就能用；还要在 Agent 的 MCP 标签里启用它。",
                   steps: [.init(kind: .plug, summary: "接入 MCP 服务「Notion」", allowed: true)],
                   result: .init(title: "已接入 Notion", meta: "已加进列表 · 等你在浏览器里登录")),
        BobExample(id: 7, group: .settings, question: "关掉消息提示音",
                   answer: "关掉了，Agent 回复时不再响。想开回来，跟我说一声，或者去「设置 → 通知」。",
                   steps: [.init(kind: .bell, summary: "关掉提示音", allowed: true)],
                   result: .init(title: "提示音已关闭", meta: "设置 · 通知")),
        BobExample(id: 8, group: .work, question: "按 requirement-brief 的做法，帮我看看 PRD/会员.md 哪里没写清楚",
                   answer: "看完了，有 3 处没说清：会员等级怎么升降、积分什么时候过期、退款后积分怎么扣。每一处我都写了建议的问法，要我写进文件里吗？",
                   steps: [.init(kind: .skill, summary: "读 Skill「requirement-brief」"), .init(kind: .read, summary: "读取 PRD/会员.md")]),
        BobExample(id: 9, group: .work, question: "把这张截图里的报错整理成缺陷单，存进项目", attachment: "粘贴图片.png",
                   answer: "整理好了，存成「缺陷/登录报错.md」：复现步骤、实际和预期，以及截图里的报错原文。不满意的话，点那一步下面的「撤销」。",
                   steps: [.init(kind: .write, summary: "写入 缺陷/登录报错.md", allowed: true)],
                   result: .init(title: "已写好「登录报错.md」", meta: "demo/缺陷/登录报错.md")),
        BobExample(id: 10, group: .work, question: "打开备忘录，新建一条写着「明天 10 点评审」的笔记",
                   answer: "建好了，在备忘录最上面。",
                   steps: [.init(kind: .computer, summary: "让 Bob 操作电脑", allowed: true), .init(kind: .terminal, summary: "运行脚本 · 备忘录")],
                   needs: "要先在上面打开「允许操作电脑」（官网版）。"),
    ]
}
