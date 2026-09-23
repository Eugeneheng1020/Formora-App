import Foundation

/// `/skills`、`/mcp`、`/hooks` + what's wanted (user 2026-09-23): drafted in one go like `/agent` (`Creations` has the prompts),
/// made at once when it only writes words (a Skill), readied for one 允许 when it runs things (an MCP service, a Hook). In a
/// conversation the outcome is a line of the thread and the 允许 waits above the composer; in Bob's panel it is his reply and
/// a card there.
extension AppState {
    /// Drafts what the words ask for. `agent`: whom a new Skill is enabled for; `projectRoot`: where a Hook goes.
    func draftCreation(_ kind: Creations.Kind, words: String, models: [ModelReference], agent: AgentRecord?,
                       projectRoot: URL?) async -> Creations.Outcome {
        guard !models.isEmpty else { return .failed("先在「设置 → 模型」配一个模型，或去「设置 → Bob」选一个") }
        if kind == .hook {
            guard let projectRoot else { return .failed("先打开一个项目：Hook 建在项目里") }
            // A project file nobody here has looked at yet isn't turned on by adding to it (the Hooks page asks first).
            let project = hooks.project(projectRoot)
            if project.exists, !project.isTrusted {
                return .failed("这个项目的 Hooks 文件还没启用：先去「设置 → Hooks」看过里面有什么、点「启用」，再用 /hooks")
            }
        }
        // A key typed in the words stays here: the model sees a placeholder, the arguments get the value back.
        let asked = SecretShield.shared.hide(words, typedByUser: true).text
        var problem: String?
        for _ in 0..<2 {
            guard let reply = await chat.oneShot(system: Creations.system(kind), prompt: Creations.request(asked, problem: problem),
                                                 candidates: models, thinks: false) else {
                return .failed("模型没有回复。检查一下模型和网络，再发一次 \(kind.command) \(asked)")
            }
            switch kind {
            case .skill:
                switch Creations.skill(reply.summary) {
                case .failure(let why): problem = why.message
                case .success(let draft):
                    // `nil`: the name or the library refused it — asked again with why.
                    if let outcome = makeSkill(draft, agent: agent, problem: &problem) { return outcome }
                }
            case .mcp:
                switch Creations.mcpArguments(reply.summary) {
                case .failure(let why) where why.final: return .failed(why.message)
                case .failure(let why): problem = why.message
                case .success(let arguments):
                    switch MCPConnect.plan(SecretShield.shared.restore(arguments), store: mcp) {
                    case let .answer(result, _):
                        return result.status == .done ? .made(title: "没有重复接入", detail: result.output) : .failed(result.output)
                    case let .add(server, secrets):
                        let shown = Creations.mcpLines(server)
                        return .confirm(Creations.Pending(kind: .mcp, title: "接入 MCP 服务「\(server.name)」", lines: shown.lines,
                                                          code: shown.code, payload: .mcp(server: server, secrets: secrets)))
                    }
                }
            case .hook:
                switch Creations.hook(reply.summary) {
                case .failure(let why): problem = why.message
                case .success(let draft):
                    guard let projectRoot else { return .failed("先打开一个项目：Hook 建在项目里") }
                    let shown = Creations.hookLines(draft)
                    return .confirm(Creations.Pending(kind: .hook, title: "新建 Hook：\(draft.event.label)", lines: shown.lines, code: shown.code,
                                                      payload: .hook(draft.handler, event: draft.event, matcher: draft.matcher, root: projectRoot)))
                }
            }
        }
        return .failed("模型两次都没写出能用的\(kind.label)（\(problem ?? "原因不明")）。写得更具体些再试一次 \(kind.command)")
    }

    /// Saved with its English name; `nil` asks the model again (the name couldn't be folded, or the library refused it).
    private func makeSkill(_ draft: Creations.SkillDraft, agent: AgentRecord?, problem: inout String?) -> Creations.Outcome? {
        guard let name = Creations.skillName(draft.name, taken: skills.skills.map(\.name)) else {
            problem = "name「\(draft.name)」不是英文（小写字母、数字和 -，字母开头，比如 weekly-report）"
            return nil
        }
        do {
            let skill = try skills.create(name: name, description: draft.description, body: draft.instructions)
            var detail = [draft.description, "/skill:\(skill.id) 使用"]
            if let agent, let current = agents.agent(agent.id) {
                try? agents.setSkill(current, skill.id, enabled: true)
                detail[1] += " · 已为\(current.displayName)启用"
            }
            return .made(title: "已创建 Skill \(skill.name)", detail: detail.joined(separator: "\n"))
        } catch let refused as SkillProblem {
            problem = refused.message
            return nil
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 允许 on an MCP service or a Hook: made now.
    func applyCreation(_ pending: Creations.Pending) async -> Creations.Outcome {
        switch pending.payload {
        case let .mcp(server, secrets):
            let result = await MCPConnect.add(server, secrets: secrets, store: mcp)
            return result.status == .done ? .made(title: "已接入 MCP 服务 \(server.name)", detail: result.output) : .failed(result.output)
        case let .hook(handler, event, matcher, root):
            var file = hooks.file(.project(root))
            file.add(handler, event: event, matcher: matcher)
            do {
                try hooks.save(file, to: .project(root))
                return .made(title: "已创建 Hook：\(event.label)", detail: (pending.code ?? "") + "\n存在本项目，已启用；在「设置 → Hooks」里改或删")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    // MARK: In a conversation

    /// The command in a conversation: a card while it drafts, a line when it's done, the 允许 above the composer.
    func createFromCommand(_ kind: Creations.Kind, words: String, in id: UUID, boardCard: String? = nil) {
        guard let conversation = conversations.conversation(id) else { return }
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            toasts.show("\(kind.command) 要写上内容", note: kind.example, isError: true)
            return
        }
        let shown = SecretShield.shared.hide(words, typedByUser: true).text
        commandCards[id] = CommandCard(kicker: kind.rawValue, title: "正在创建\(kind.label)…", body: .text(shown))
        let agent = conversation.isGroup ? nil : commandAgent(conversation)
        let models = drafterModels(for: conversation)
        let root = files?.root.url
        Task { [weak self] in
            guard let self else { return }
            let outcome = await draftCreation(kind, words: words, models: models, agent: agent, projectRoot: root)
            sayCreation(kind, outcome, in: id, boardCard: boardCard)
        }
    }

    /// 允许 or 不用了 on the card above the composer.
    func resolveCreation(in id: UUID, allow: Bool) {
        guard let pending = pendingCreations[id] else { return }
        pendingCreations[id] = nil
        guard allow else {
            toasts.show("没有创建", note: pending.title, seconds: 2)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            sayCreation(pending.kind, await applyCreation(pending), in: id, boardCard: nil)
        }
    }

    private func sayCreation(_ kind: Creations.Kind, _ outcome: Creations.Outcome, in id: UUID, boardCard: String?) {
        guard conversations.conversation(id) != nil else { return }
        commandCards[id] = nil
        let event: ThreadEvent
        switch outcome {
        case .confirm(let pending):
            pendingCreations[id] = pending
            return
        case let .made(title, detail):
            var made = ThreadEvent(kind: .created, title: title, detail: detail)
            made.passed = true
            event = made
            toasts.show(title, seconds: 3)
        case .failed(let reason):
            var failed = ThreadEvent(kind: .created, title: "\(kind.label)没创建成功", detail: reason)
            failed.passed = false
            event = failed
        }
        var message = Message(role: .user, text: "", event: event)
        message.boardCard = boardCard
        conversations.append(message, to: id)
    }

    // MARK: In Bob's panel

    /// Bob's `/skills`, `/mcp`, `/hooks` (user 2026-09-23): his model drafts it; the outcome is his reply, the 允许 a card.
    func createForBob(_ kind: Creations.Kind, words: String) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = SecretShield.shared.hide(words, typedByUser: true).text
        bob.noteCommand("\(kind.command) \(shown)".trimmingCharacters(in: .whitespaces))
        guard !words.isEmpty else {
            bob.noteReply("", failure: kind.example)
            return
        }
        let models = [chat.conductorModel()].compactMap { $0 }
        let root = files?.root.url
        bobCreating = kind
        Task { [weak self] in
            guard let self else { return }
            let outcome = await draftCreation(kind, words: words, models: models, agent: nil, projectRoot: root)
            bobCreating = nil
            sayToBob(kind, outcome)
        }
    }

    func resolveBobCreation(allow: Bool) {
        guard let pending = bobPendingCreation else { return }
        bobPendingCreation = nil
        guard allow else {
            bob.noteReply("好，没有创建。")
            return
        }
        bobCreating = pending.kind
        Task { [weak self] in
            guard let self else { return }
            let outcome = await applyCreation(pending)
            bobCreating = nil
            sayToBob(pending.kind, outcome)
        }
    }

    private func sayToBob(_ kind: Creations.Kind, _ outcome: Creations.Outcome) {
        switch outcome {
        case .confirm(let pending): bobPendingCreation = pending
        case let .made(title, detail): bob.noteReply(title + "\n\n" + detail)
        case .failed(let reason): bob.noteReply("", failure: "\(kind.label)没创建成功：\(reason)")
        }
    }
}
