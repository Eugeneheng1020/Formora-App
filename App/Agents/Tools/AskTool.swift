import Foundation

/// The `ask` tool (7d, D6; old app 2026-09-07 「A，多选也要做」; omp `ask`, codex `request_user_input`): the Agent puts a
/// decision to the user as options. The run ends on the call and carries on with the answer; the open call is kept
/// on disk, so a question outlives a restart. No timeout — omp's auto-pick after one was declined.
enum AskTool {
    static let spec = ToolSpec(
        name: "ask",
        description: "Put a decision to the user as options to pick. Only for choices whose consequences differ in ways the user must weigh, and that you can't settle from the project, the conversation or sensible defaults — otherwise take the conventional option, go on, and say what you chose. Up to 4 related questions in one call, each with 2 to 5 short, distinct options; give every option a one-line description of what choosing it means. multi: true lets the user pick several; recommended is the 0-based index of the option you would pick. Don't add an \"other\" option: the user can always answer in their own words. Your turn ends with this call and continues once the user has answered.",
        parameters: #"{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label"]}},"multi":{"type":"boolean"},"recommended":{"type":"integer"}},"required":["question","options"]}}},"required":["questions"]}"#,
        tier: .read)

    static let questionLimit = 4
    static let optionLimit = 6

    struct Option: Codable, Equatable, Sendable {
        var label: String
        var description: String?
    }

    struct Question: Codable, Equatable, Sendable {
        var question: String
        var options: [Option]
        var multi = false
        var recommended: Int?
    }

    /// One question's answer: options picked, or words typed, or neither.
    struct Answer: Codable, Equatable, Sendable {
        var picked: [String] = []
        var typed: String?
    }

    struct Problem: Error, Equatable {
        let message: String
    }

    static func parse(_ json: String) -> Result<[Question], Problem> {
        func fail(_ message: String) -> Result<[Question], Problem> { .failure(Problem(message: message + "。问题没有问出去，改好再问。")) }
        guard let args = ToolArguments.parse(json) else { return fail("参数不是合法的 JSON 对象") }
        guard let raw = args["questions"] as? [Any], !raw.isEmpty else { return fail("需要 questions：至少一个问题") }
        guard raw.count <= questionLimit else { return fail("一次最多问 \(questionLimit) 个问题") }
        var questions: [Question] = []
        for entry in raw {
            guard let object = entry as? [String: Any],
                  let text = (object["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return fail("每个问题都要写 question")
            }
            let options: [Option] = ((object["options"] as? [Any]) ?? []).compactMap { option in
                // A bare string is taken as a label (omp's renderer does the same).
                if let label = (option as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    return label.isEmpty ? nil : Option(label: label)
                }
                guard let fields = option as? [String: Any],
                      let label = (fields["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                let description = (fields["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Option(label: label, description: description?.isEmpty == false ? description : nil)
            }
            guard options.count >= 2 else { return fail("「\(text)」至少要有两个选项") }
            guard options.count <= optionLimit else { return fail("「\(text)」的选项太多，最多 \(optionLimit) 个") }
            let recommended = ToolArguments.int(object, "recommended").flatMap { options.indices.contains($0) ? $0 : nil }
            questions.append(Question(question: text, options: options, multi: object["multi"] as? Bool ?? false, recommended: recommended))
        }
        return .success(questions)
    }

    /// What the model reads: each question and what the user said to it.
    static func text(_ questions: [Question], _ answers: [Answer]) -> String {
        var lines = ["用户的回答："]
        for (index, question) in questions.enumerated() {
            let answer = index < answers.count ? answers[index] : Answer()
            let said: String
            if !answer.picked.isEmpty {
                said = answer.picked.joined(separator: "、") + "（从选项里选的）"
            } else if let typed = answer.typed, !typed.isEmpty {
                said = "没有选选项，直接说：「\(typed)」"
            } else {
                said = "没有回答"
            }
            lines.append("\(index + 1). \(question.question) → \(said)")
        }
        return lines.joined(separator: "\n")
    }
}
