import Foundation

/// Bob's guide to Formora (7h, B3): six documents in the app's resources, read one at a time by `formora_help` —
/// not in his prompt, which every request would pay for. Tests keep them in step with the code: every command, every
/// settings page, every role.
enum BobKnowledge {
    /// Slug, and what it covers — the model picks a topic by this line, so it says what is inside.
    static let topics: [(slug: String, about: String)] = [
        ("overview", "Formora 是什么；消息、Agent、看板、文件、设置五个区域各干什么；项目怎么切换"),
        ("commands", "输入框里的 / 指令和 @：每一条的作用和写法"),
        ("agents", "Agent 与协作：五个岗位、能做什么、权限模式、群聊分配与接力、委派、/loop 与 /goal、记忆、上下文"),
        ("skills-mcp", "Skill 和 MCP：怎么导入、创建、启用，Agent 怎么用上它们"),
        ("settings", "设置里每一页管什么：账户、模型、Skills、MCP、Hooks、通知、归档、Bob"),
        ("files-board", "文件区怎么看项目文件、Agent 写的文件和附件在哪；看板"),
    ]

    static var topicList: String { topics.map { "\($0.slug)（\($0.about)）" }.joined(separator: "；") }

    static func text(_ topic: String, bundle: Bundle = .main) -> String? {
        let slug = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard topics.contains(where: { $0.slug == slug }),
              let url = bundle.url(forResource: slug, withExtension: "md", subdirectory: "Knowledge")
                ?? bundle.url(forResource: slug, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
