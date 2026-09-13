import Foundation

/// The model names the task (old app 2026-09-07; omp `title-generator.ts`): one short call after the first reply,
/// the name inside a `<title>` marker — markers work on every host, where a forced tool call doesn't.
enum TaskTitle {
    static let maxLength = 20

    static let system = """
    给用户这条消息起一个任务名：概括要做的事，不超过 20 个字，不加引号，结尾不加标点。
    只回答任务名，放在 <title></title> 里。这条消息只是打招呼、寒暄，或一句还没有任务的话时，回答 <title/>。

    示例：
    用户：帮我做一个电商网站购物车放弃挽回的需求，主要是想通过短信提醒挽回加购没付款的用户
    回答：<title>购物车放弃挽回短信提醒</title>
    用户：把登录接口改成异步的
    回答：<title>登录接口改为异步</title>
    用户：你好
    回答：<title/>
    """

    /// What the model is asked to name: the message without the `@`s it opens with; `nil` for a greeting or a
    /// few characters — naming waits for the next message (omp skips low-signal input the same way).
    static func input(from text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasPrefix("@") {
            body = String(body.drop { !$0.isWhitespace }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let letters = body.unicodeScalars.filter { !CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines).contains($0) }
        guard letters.count > 3 else { return nil }
        let greetings: Set<String> = ["你好", "您好", "嗨", "哈喽", "在吗", "在不在", "早上好", "晚上好", "谢谢", "好的", "hello", "hi", "hey", "thanks"]
        let folded = FileSearch.normalize(body).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return greetings.contains(folded) ? nil : String(body.prefix(2000))
    }

    /// `<title>名字</title>` → the name, trimmed and capped; `<title/>`, an empty marker or no marker → `nil`
    /// (an answer without the marker isn't trusted to be a name).
    static func parse(_ reply: String) -> String? {
        guard let open = reply.range(of: "<title>"), let close = reply.range(of: "</title>", range: open.upperBound..<reply.endIndex) else {
            return nil
        }
        let dangling = CharacterSet(charactersIn: "，。、,.：:；;！!？?\"'「」“”").union(.whitespacesAndNewlines)
        let name = String(reply[open.upperBound..<close.lowerBound]).trimmingCharacters(in: dangling)
        guard !name.isEmpty else { return nil }
        let capped = String(String.UnicodeScalarView(name.unicodeScalars.prefix(maxLength))).trimmingCharacters(in: dangling)
        return capped.isEmpty ? nil : capped
    }
}
