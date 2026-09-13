import Foundation

/// `/export` and `/dump` (7d, D2): the conversation as the user saw it — who said what and when, what the Agent did;
/// the loop's hidden nudges stay out.
@MainActor
enum ConversationExport {
    struct Entry: Equatable {
        let who: String
        let time: Date
        let text: String
        let isUser: Bool
    }

    static func entries(_ conversation: Conversation, agents: AgentStore, userName: String) -> [Entry] {
        let user = userName.trimmingCharacters(in: .whitespaces).isEmpty ? "我" : userName
        return conversation.messages.filter { !$0.isHidden }.map { message in
            var parts: [String] = []
            if !message.text.isEmpty { parts.append(message.text) }
            if let failure = message.failure { parts.append("（没有回复：\(failure)）") }
            for call in message.toolCalls {
                let outcome = switch call.result?.status {
                case .done: "完成"
                case .failed: "失败"
                case .denied: "被拒绝"
                case .stopped, nil: "没有执行"
                }
                parts.append("· \(call.summary)（\(outcome)）")
            }
            if !message.attachments.isEmpty { parts.append("附件：" + message.attachments.map(\.relativePath).joined(separator: "、")) }
            let who = message.role == .user ? user
                : agents.agent(message.agentID)?.displayName ?? message.speakerName ?? ConversationReadiness.deletedAgentName
            return Entry(who: who, time: message.createdAt, text: parts.joined(separator: "\n"), isUser: message.role == .user)
        }
    }

    static func plainText(_ conversation: Conversation, agents: AgentStore, userName: String, projectName: String?) -> String {
        var lines = ["# \(conversation.title)", header(conversation, agents: agents, projectName: projectName), ""]
        for entry in entries(conversation, agents: agents, userName: userName) {
            lines.append("[\(stamp(entry.time))] \(entry.who)：\(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    static func html(_ conversation: Conversation, agents: AgentStore, userName: String, projectName: String?) -> String {
        let rows = entries(conversation, agents: agents, userName: userName).map { entry in
            """
            <div class="row\(entry.isUser ? " user" : "")"><div class="who">\(escape(entry.who)) · \(stamp(entry.time))</div>
            <div class="text">\(escape(entry.text))</div></div>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><title>\(escape(conversation.title))</title>
        <style>
        body{background:#09090B;color:#F1F1EF;font:14px -apple-system,"PingFang SC",sans-serif;margin:0;padding:40px}
        .wrap{max-width:720px;margin:0 auto}h1{font-size:20px}.meta{color:#8A8C91;font-size:12px;margin-bottom:28px}
        .row{margin-bottom:18px}.who{color:#55575C;font-size:11px;margin-bottom:5px}
        .text{white-space:pre-wrap;line-height:1.65;background:#131316;border:1px solid #201F23;border-radius:12px;padding:11px 14px}
        .row.user .text{background:#28292D;border-color:#322F35}
        </style></head>
        <body><div class="wrap"><h1>\(escape(conversation.title))</h1>
        <div class="meta">\(escape(header(conversation, agents: agents, projectName: projectName))) · 导出于 \(stamp(.now))</div>
        \(rows)
        </div></body></html>
        """
    }

    /// The save panel's name: the task name, without what a file name can't hold.
    static func fileName(_ conversation: Conversation) -> String {
        let cleaned = conversation.title.replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "对话" : cleaned) + ".html"
    }

    private static func header(_ conversation: Conversation, agents: AgentStore, projectName: String?) -> String {
        var parts: [String] = []
        if let projectName { parts.append("项目：\(projectName)") }
        parts.append(conversation.isGroup ? "群聊：\(conversation.groupName)" : "Agent：\(ConversationReadiness.headline(of: conversation, agents: agents))")
        return parts.joined(separator: "　")
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
