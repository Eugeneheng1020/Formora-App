import AppKit
import ApplicationServices
import Foundation

/// Launch-argument hooks for UI tests and screenshots. Honoured **only** in a named profile
/// (e.g. `-FormoraProfile qa`), so they can never touch the user's real data. All are `-key value` pairs.
@MainActor
enum VerificationHooks {
    /// `-FormoraPickFolder <name>`: the folder picker returns `<support>/Picked/<name>` instead of a system panel.
    static let pickFolderKey = "FormoraPickFolder"
    /// `-FormoraSeedProjects a,b`: registers `<support>/Seeded/a` and `b`; the first becomes current if none is.
    static let seedProjectsKey = "FormoraSeedProjects"
    /// `-FormoraSection agents`: opens on that rail section.
    static let sectionKey = "FormoraSection"
    /// `-FormoraSelectFile docs/PRD.md`: selects that file (relative to the open project) in 文件.
    static let selectFileKey = "FormoraSelectFile"

    /// Seeded projects are filled from `<container tmp>/FormoraFixtures/<name>` when a script staged one there
    /// (`scripts/app-snapshot.sh` stages `TestProject`); otherwise they start empty.
    static var fixturesFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FormoraFixtures", isDirectory: true)
    }

    /// `-FormoraHTMLView source`: HTML files open on 源码 instead of 预览.
    static let htmlViewKey = "FormoraHTMLView"

    static func htmlView(for profile: AppProfile, settings: UserDefaults = .standard) -> HTMLViewMode? {
        guard !profile.isDefault, let raw = settings.string(forKey: htmlViewKey) else { return nil }
        return HTMLViewMode(rawValue: raw)
    }

    static func fileToSelect(for profile: AppProfile, settings: UserDefaults = .standard) -> String? {
        guard !profile.isDefault else { return nil }
        return settings.string(forKey: selectFileKey)
    }

    static func folderPicker(for profile: AppProfile, settings: UserDefaults = .standard) -> FolderPicking {
        guard !profile.isDefault,
              let name = settings.string(forKey: pickFolderKey), !name.isEmpty,
              let support = try? profile.applicationSupportDirectory() else {
            return OpenPanelFolderPicker()
        }
        return ProfileFolderPicker(root: support.appendingPathComponent("Picked", isDirectory: true), name: name)
    }

    static func seedProjects(into store: ProjectStore, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault,
              let raw = settings.string(forKey: seedProjectsKey),
              let support = try? profile.applicationSupportDirectory() else { return }
        let names = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { ProjectNameRule.problem(with: $0) == nil }
        var first: ProjectRecord?
        for name in names {
            let url = support.appendingPathComponent("Seeded", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            let fixture = fixturesFolder.appendingPathComponent(name, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: fixture.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: fixture, to: url)
            }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let record = store.upsert(folder: url, bookmark: ProjectFolders.makeBookmark(for: url), summary: nil)
            if first == nil { first = record }
        }
        if store.current == nil, let first { store.currentID = first.id }
    }

    static func initialSection(for profile: AppProfile, settings: UserDefaults = .standard) -> AppSection? {
        guard !profile.isDefault, let raw = settings.string(forKey: sectionKey) else { return nil }
        return AppSection(rawValue: raw)
    }

    /// `-FormoraOverlay <name>` opens a screen that normally needs a click, so it can be screenshotted
    /// without UI automation: `projectMenu`, `newProjectMenu`, `manage`, `launchNewProject`, and the cold start's
    /// `launchModel`, `launchAgent`, `launchReady` (9f).
    static let overlayKey = "FormoraOverlay"

    /// `-FormoraSettingsCategory models`: 设置 opens on that category.
    static let settingsCategoryKey = "FormoraSettingsCategory"
    /// `-FormoraProviderEditor deepseek` (or `new`): the provider dialog opens.
    static let providerEditorKey = "FormoraProviderEditor"
    /// `-FormoraShowModels deepseek,qwen`: those providers' model lists start expanded.
    static let showModelsKey = "FormoraShowModels"
    /// `-FormoraAvatarFixture TestProject/site/images/logo.png`: imported as the avatar, relative to `fixturesFolder`.
    static let avatarFixtureKey = "FormoraAvatarFixture"
    /// `FORMORA_QA_KEY_<PROVIDER>` — environment only, never an argument (arguments show up in `ps`).
    static let providerKeyEnvironmentPrefix = "FORMORA_QA_KEY_"

    static func applySettings(to state: AppState, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault else { return }
        if let raw = settings.string(forKey: settingsCategoryKey), let category = SettingsCategory(rawValue: raw) {
            state.settingsCategory = category
        }
        if let raw = settings.string(forKey: providerEditorKey) {
            state.providerEditor = raw == "new" ? .newCustom : .provider(raw)
        }
        if let raw = settings.string(forKey: showModelsKey) {
            let ids = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            state.openModelLists = Set(ids)
            for id in ids { Task { await state.providers.loadModels(id) } }
        }
    }

    /// Saves keys handed over in the environment into this profile's own Keychain service, then tests them.
    static func seedProviderKeys(into store: ProviderStore, profile: AppProfile,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !profile.isDefault else { return }
        for provider in ProviderCatalog.builtIns {
            guard let key = environment[providerKeyEnvironmentPrefix + provider.id.uppercased()], !key.isEmpty,
                  (try? store.saveKey(key, for: provider.id)) != nil else { continue }
            Task { await store.loadModels(provider.id) }
        }
    }

    static func seedAccount(_ account: AccountStore, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault, let path = settings.string(forKey: avatarFixtureKey) else { return }
        try? account.importAvatar(from: fixturesFolder.appendingPathComponent(path))
    }

    /// `-FormoraSeedAgents YES`: four sample Agents (one stopped, one on a provider without a key).
    static let seedAgentsKey = "FormoraSeedAgents"
    /// `-FormoraAgentTab model`: the Agent page opens on that tab.
    static let agentTabKey = "FormoraAgentTab"
    /// `-FormoraAllowComputer YES`: every seeded Agent has 允许操作电脑 on (7j, B3).
    static let allowComputerKey = "FormoraAllowComputer"
    /// `-FormoraAgentScroll end`: the Agent page starts scrolled to its end, where 模型与权限's switches are.
    static let agentScrollKey = "FormoraAgentScroll"
    static var agentScrollsToEnd: Bool { UserDefaults.standard.string(forKey: agentScrollKey) == "end" }
    /// `-FormoraCreateAgentStep 1|2|3`: the creation dialog opens prefilled on that step.
    static let createAgentStepKey = "FormoraCreateAgentStep"

    static func applyAgents(to state: AppState, currentProject: ProjectRecord?, profile: AppProfile,
                            settings: UserDefaults = .standard) {
        guard !profile.isDefault else { return }
        if settings.bool(forKey: seedAgentsKey), state.agents.agents.isEmpty, let project = currentProject {
            let samples: [(role: String, name: String, provider: String, model: String, active: Bool)] = [
                ("ops", "增长", "deepseek", "deepseek-v4-flash", false),
                ("qa", "验收", "openai", "gpt-5.4-mini", true),
                ("dev", "前端", "deepseek", "deepseek-v4-flash", true),
                ("design", "小设", "deepseek", "deepseek-v4-pro", true),
            ]
            for sample in samples {
                guard let agent = try? state.agents.create(NewAgent(roleID: sample.role, name: sample.name, subtitle: "",
                                                                   avatarPNG: nil, providerID: sample.provider,
                                                                   modelID: sample.model, projectIDs: [project.id])) else { continue }
                if !sample.active { try? state.agents.setActive(agent, false) }
                if sample.role == "design" {
                    for skill in ["requirement-brief", "implementation-plan"] where state.skills.skill(skill) != nil {
                        try? state.agents.setSkill(agent, skill, enabled: true)
                    }
                }
            }
            state.selectedAgentID = state.agents.agents.first?.id
        }
        if let raw = settings.string(forKey: agentTabKey), let tab = AppState.AgentTab(rawValue: raw) { state.agentTab = tab }
        if settings.bool(forKey: allowComputerKey) {
            for agent in state.agents.agents { try? state.agents.setAllowsComputer(agent, true) }
        }
        if let raw = settings.string(forKey: createAgentStepKey), let number = Int(raw), let step = CreateAgentFlow.Step(rawValue: number) {
            var flow = CreateAgentFlow(agents: state.agents, providers: state.providers, currentProject: currentProject?.id)
            if step != .identity { flow.name = "新同事" }
            flow.step = step
            state.createAgentPreset = flow
            state.isCreatingAgent = true
        }
    }

    /// `-FormoraSeedMCP YES`: DeepWiki (public, no sign-in — tested for real at launch), GitHub (no token yet),
    /// Linear (browser sign-in, untested) and Playwright (stdio).
    static let seedMCPKey = "FormoraSeedMCP"
    /// `-FormoraMCPDialog catalog|paste|manual`: the add dialog opens on that layer.
    static let mcpDialogKey = "FormoraMCPDialog"
    static let deepWikiURL = "https://mcp.deepwiki.com/mcp"
    /// `-FormoraFakeMCP <url>`: a local MCP server (scripts/fake-llm.py serves one at /mcp) added and granted (7f).
    static let fakeMCPKey = "FormoraFakeMCP"
    /// `-FormoraTestMCP playwright` (with `-FormoraSeedMCP YES`, 9d): that seeded catalog server is tested at launch — a
    /// real stdio start, `npx -y` download and all.
    static let testMCPKey = "FormoraTestMCP"

    static func applyMCP(to state: AppState, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault else { return }
        if settings.bool(forKey: seedMCPKey), state.mcp.servers.isEmpty {
            let deepWiki = MCPServerConfig(id: MCPServerConfig.newID(), name: "DeepWiki", transport: .http(url: deepWikiURL))
            if let id = try? state.mcp.add(deepWiki, secrets: [:]) {
                Task {
                    await state.mcp.test(id, allowSignIn: false)
                    if let agent = state.agents.agents.first, let tools = state.mcp.server(id)?.tools, !tools.isEmpty {
                        try? state.agents.saveMCP(agent, [MCPAccess(serverID: id, mode: .selected, toolNames: [tools[0].name])])
                    }
                }
            }
            for entryID in ["github", "linear", "playwright"] {
                if let entry = MCPCatalogEntry.entry(entryID) { _ = try? state.mcp.add(entry.config(name: "", token: "").server, secrets: [:]) }
            }
        }
        if let wanted = settings.string(forKey: testMCPKey), let server = state.mcp.servers.first(where: { $0.catalogID == wanted }) {
            Task { await state.mcp.test(server.id, allowSignIn: false) }
        }
        if let raw = settings.string(forKey: mcpDialogKey), let mode = AppState.MCPAddMode(rawValue: raw) {
            state.mcpDialog = .add(mode)
        }
        // `-FormoraFakeMCP http://127.0.0.1:8765/mcp` (7f): the local fake server as 「Docs」, tested, every tool for every Agent.
        if let url = settings.string(forKey: fakeMCPKey), !state.mcp.servers.contains(where: { $0.name == "Docs" }),
           let id = try? state.mcp.add(MCPServerConfig(id: MCPServerConfig.newID(), name: "Docs", transport: .http(url: url)), secrets: [:]) {
            Task {
                await state.mcp.test(id, allowSignIn: false)
                for agent in state.agents.agents { try? state.agents.saveMCP(agent, [MCPAccess(serverID: id)]) }
            }
        }
    }

    /// `-FormoraSeedConversations YES` (with `-FormoraSeedAgents YES`): a group, direct chats of several ages,
    /// one done, one hidden, one archived — the states the list has to show.
    static let seedConversationsKey = "FormoraSeedConversations"
    /// `-FormoraConversation 1`: selects that row of the current view.
    static let conversationKey = "FormoraConversation"
    /// `-FormoraMessageSearch 短信`: types into the list's search.
    static let messageSearchKey = "FormoraMessageSearch"
    /// `-FormoraGroupDialog create|settings`: the group dialog opens (settings: the first group).
    static let groupDialogKey = "FormoraGroupDialog"
    /// `-FormoraHiddenView YES`: opens 「已隐藏的会话」.
    static let hiddenViewKey = "FormoraHiddenView"
    /// `-FormoraComposerDraft YES`: the selected conversation's composer holds two attachments.
    static let composerDraftKey = "FormoraComposerDraft"
    /// `-FormoraReasoningMenu YES`: the reasoning menu opens on the selected conversation.
    static let reasoningMenuKey = "FormoraReasoningMenu"

    static func applyMessages(to state: AppState, currentProject: ProjectRecord?, profile: AppProfile,
                              settings: UserDefaults = .standard) {
        guard !profile.isDefault else { return }
        let store = state.conversations
        if settings.bool(forKey: seedConversationsKey), store.conversations.isEmpty, let project = currentProject {
            seedConversations(into: state, project: project.id)
        }
        let hidden = settings.bool(forKey: hiddenViewKey)
        state.showsHiddenConversations = hidden
        let list = store.list(project: currentProject?.id, hiddenView: hidden)
        if let raw = settings.string(forKey: conversationKey), let index = Int(raw), list.indices.contains(index) {
            state.selectedConversationID = list[index].id
        } else {
            state.selectedConversationID = list.first?.id
        }
        if let query = settings.string(forKey: messageSearchKey) { state.messageSearch = query }
        // `-FormoraSeedLaneCopies YES` (10l): two members of the selected group came back from their copies — one's changes
        // merged, the other's version of the same file kept beside it — each reply saying so.
        if settings.bool(forKey: seedLaneCopiesKey), let id = state.selectedConversationID, let conversation = store.conversation(id),
           conversation.members.count >= 2 {
            let first = conversation.members[0].agentID, second = conversation.members[1].agentID
            let firstName = state.agents.agent(first)?.displayName ?? "Agent", secondName = state.agents.agent(second)?.displayName ?? "Agent"
            let path = "PRD/满减规则.md"
            store.append(Message(role: .user, text: "@\(firstName) @\(secondName) 一起把满减门槛改成 50"), to: id)
            var merged = Message(role: .agent, agentID: first, speakerName: firstName, text: "门槛改成了满 50 减 8，例子一起改了。", runID: UUID())
            merged.note = LaneCopies.note(LaneCopies.Merge(applied: [path]))
            var kept = Message(role: .agent, agentID: second, speakerName: secondName, text: "我把门槛写成了满 50 减 10，并补了一条测试用例。",
                               runID: UUID())
            kept.note = LaneCopies.note(LaneCopies.Merge(kept: [LaneCopies.Merge.Kept(path: path, copy: "PRD/满减规则（\(secondName)的版本）.md")]))
            store.append(merged, to: id)
            store.append(kept, to: id)
        }
        // `-FormoraSeedReview YES` (10k): the selected conversation shows a /review — 需要改, a P0, a P1 and a P3.
        if settings.bool(forKey: seedReviewKey), let id = state.selectedConversationID, let conversation = store.conversation(id),
           let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let review = Advisor.Review(passes: false, summary: "技术方案整体可行，但重试和幂等两处要先补上，才能交给测试。", findings: [
                Advisor.Finding(level: 0, title: "短信重试没有上限", place: "docs/tech/sms_retry.md",
                                detail: "通道失败时会一直重试；通道故障时，可能给同一个用户连发几十条。"),
                Advisor.Finding(level: 1, title: "没写幂等键由谁生成", place: "docs/tech/sms_retry.md",
                                detail: "订单服务和短信服务都可能生成，两边不一致时就去不了重。"),
                Advisor.Finding(level: 3, title: "时序图可以标上超时时间", place: nil, detail: ""),
            ])
            store.append(Advisor.message(review, agentID: agentID, runID: UUID()), to: id)
        }
        // `-FormoraSeedMemory YES` (10j): the selected conversation's Agent remembers a few things, one of them gone stale,
        // and /memory is open.
        if settings.bool(forKey: seedMemoryKey), let id = state.selectedConversationID, let conversation = store.conversation(id),
           let agent = state.commandAgent(conversation), let memory = state.chat.memory {
            let day = { (offset: Double) in MemoryStore.day(Date.now.addingTimeInterval(offset * 86_400)) }
            memory.rewrite("""
            ## 用户偏好
            - 先给结论，再给要点（\(day(-3))）
            ## 项目约定
            - 金额一律写到分（\(day(-20))）
            - 需求用飞书文档管理（\(day(-240))）
            ## 已定的结论
            - 短信重试最多 3 次（\(day(-9))）
            """, agent: agent.id, project: conversation.projectID)
            state.commandCards[id] = CommandCard(kicker: "memory", title: "\(agent.displayName) 的记忆", body: .memory)
        }
        // `-FormoraSeedSide YES` (10i): a side conversation opened from the selected one — a question and its answer —
        // shown in its place, its banner on top.
        if settings.bool(forKey: seedSideKey), let id = state.selectedConversationID, let conversation = store.conversation(id),
           let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let side = store.openSide(from: conversation, agentID: agentID, title: Side.title("幂等键是什么意思"))
            store.append(Message(role: .user, text: "方案里说的「幂等键」是什么意思？"), to: side.id)
            store.append(Message(role: .agent, agentID: agentID, speakerName: state.agents.agent(agentID)?.displayName,
                                 text: "就是给每次发短信的请求一个唯一编号：同一个编号重复发来只处理一次，重试时就不会给用户发两条。", runID: UUID()),
                         to: side.id)
            state.selectedConversationID = side.id
        }
        // `-FormoraSeedAdvice YES` (10h): the selected conversation shows 旁审 at work — a step, the watcher's 担心 in the
        // Agent's frame, and what the Agent did about it.
        if settings.bool(forKey: seedAdviceKey), let id = state.selectedConversationID, let conversation = store.conversation(id),
           let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let runID = UUID()
            let name = state.agents.agent(agentID)?.displayName
            let path = "PRD/满减规则.md"
            let edit = ToolCall(id: "qa-advice-edit", name: "edit", arguments: #"{"path":"\#(path)","old_text":"满 30","new_text":"满 50"}"#,
                                result: ToolResult(status: .done, output: "已修改 \(path)：替换了 1 处", savedPath: path, isNewFile: false))
            store.append(Message(role: .user, text: "把满减门槛改成满 50 减 8"), to: id)
            store.append(Message(role: .agent, agentID: agentID, speakerName: name, text: "先改 PRD 里的门槛。", toolCalls: [edit], runID: runID),
                         to: id)
            store.append(Advisor.message(Advisor.Note(severity: .concern, text: "PRD 第 12 行的例子还写着「满 30 减 8」，和新门槛对不上，一起改掉。"),
                                         agentID: agentID, runID: runID), to: id)
            store.append(Message(role: .agent, agentID: agentID, speakerName: name, text: "例子也改好了，门槛统一成满 50 减 8。", runID: runID),
                         to: id)
        }
        // `-FormoraSeedRule YES` (10g): the open project watches one rule (管理项目 lists it), and the selected
        // conversation shows where it stopped a reply, and what the Agent wrote instead.
        if settings.bool(forKey: seedRuleKey), let project = currentProject, let id = state.selectedConversationID,
           let conversation = store.conversation(id), let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let folder = URL(fileURLWithPath: project.folderPath).appendingPathComponent(".formora/rules", isDirectory: true)
            let text = """
            ---
            condition: '\\d+(\\.\\d+)? ?元'
            scope: text
            ---
            金额一律写到分，单位写「分」，不要写「元」。
            """
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? text.write(to: folder.appendingPathComponent("金额写到分.md"), atomically: true, encoding: .utf8)
            if let rule = WatchRules.parse(text, name: "金额写到分", path: ".formora/rules/金额写到分.md") {
                let runID = UUID()
                store.append(Message(role: .user, text: "把满减规则写一句话给我"), to: id)
                var reminder = Message(role: .user, agentID: agentID, text: WatchRules.reminder(rule), runID: runID, isHidden: true,
                                       marker: WatchRules.marker(rule))
                reminder.rule = rule.name
                store.append(reminder, to: id)
                store.append(Message(role: .agent, agentID: agentID, speakerName: state.agents.agent(agentID)?.displayName,
                                     text: "订单满 3000 分减 800 分，每人每天限用一次。", runID: runID), to: id)
            }
        }
        // `-FormoraSeedJobs YES` (10f): the selected conversation has a command running in the background — a real one,
        // over by itself in two minutes — its card in the thread and its row above the composer.
        if settings.bool(forKey: seedJobsKey), let project = currentProject, let id = state.selectedConversationID,
           let conversation = store.conversation(id), let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let root = URL(fileURLWithPath: project.folderPath)
            let command = "for i in $(seq 1 120); do echo \"构建进度 $i/120\"; sleep 1; done"
            let arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: ["command": command, "background": true])) ?? Data(),
                                   as: UTF8.self)
            let name = state.agents.agent(agentID)?.displayName
            state.chat.jobs.firstWait = 0.5
            Task { @MainActor in
                let result = await state.chat.jobs.start(command, in: id, cwd: root)
                let call = ToolCall(id: "qa-job", name: "bash", arguments: arguments, result: result)
                store.append(Message(role: .agent, agentID: agentID, speakerName: name, text: "构建要跑一会儿，我放到后台了，跑完我再看结果。",
                                     toolCalls: [call], runID: UUID()), to: id)
            }
        }
        // `-FormoraSeedRewind YES` (10e): the selected conversation went back once — its line over the message that
        // replaced the first try — and that message is open in 修改, a file written after it.
        if settings.bool(forKey: seedRewindKey), let project = currentProject, let id = state.selectedConversationID,
           let conversation = store.conversation(id), let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let root = URL(fileURLWithPath: project.folderPath)
            let name = state.agents.agent(agentID)?.displayName
            func reply(_ text: String, calls: [ToolCall] = []) -> Message {
                Message(role: .agent, agentID: agentID, speakerName: name, text: text, toolCalls: calls, runID: UUID())
            }
            let first = Message(role: .user, text: "写一份双十一活动规则：满 200 减 30")
            store.append(first, to: id)
            store.append(reply("写好了，放在 PRD/双十一活动规则.md：满 200 减 30，每人限用一次。"), to: id)
            store.rewind(id, from: first.id)
            let line = store.conversation(id)?.messages.last?.id
            let edited = Message(role: .user, text: "写一份双十一活动规则：满 300 减 50，可以和店铺券叠加")
            store.append(edited, to: id)
            let path = "PRD/双十一活动规则.md"
            let content = "# 双十一活动规则\n\n- 满 300 减 50\n- 可与店铺券叠加\n"
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("PRD"), withIntermediateDirectories: true)
            try? content.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            var write = ToolCall(id: "qa-rewind-write", name: "write", arguments: #"{"path":"\#(path)","content":"…"}"#,
                                 result: ToolResult(status: .done, output: "已保存 \(path)", savedPath: path, isNewFile: true))
            write.result?.change = FileChange(added: 4, removed: 0, diff: nil, snapshot: nil, afterHash: FileChange.hash(content), wasNew: true)
            store.append(reply("规则写好了：满 300 减 50，可以和店铺券叠加。", calls: [write]), to: id)
            store.append(Message(role: .user, text: "再加一条：每人限用 3 次"), to: id)
            store.append(reply("加上了。"), to: id)
            state.editingMessage = edited.id
            // Opened at the line, not at the bottom: it and the message under it in view.
            state.messageJump = line.map { AppState.MessageJump(conversationID: id, messageID: $0) }
        }
        // `-FormoraSeedChange YES` (10d): the selected conversation shows a finished edit with its diff and 撤销, and an
        // edit waiting for 允许 with the change it would make — on a file written into the fixtures' copy.
        if settings.bool(forKey: seedChangeKey), let project = currentProject, let id = state.selectedConversationID,
           let conversation = store.conversation(id), let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let root = URL(fileURLWithPath: project.folderPath)
            let path = "PRD/会员积分规则.md"
            let before = "# 会员积分规则\n\n- 消费 1 元得 1 分\n- 100 分抵 1 元\n- 积分 12 个月后过期\n"
            let after = before.replacingOccurrences(of: "12 个月", with: "24 个月") + "- 过期前 7 天提醒\n"
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("PRD"), withIntermediateDirectories: true)
            try? after.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
            let compared = LineDiff.compare(before, after)
            var done = ToolCall(id: "qa-edit", name: "edit", arguments: #"{"path":"\#(path)","old_text":"12 个月","new_text":"24 个月"}"#,
                                result: ToolResult(status: .done, output: "已修改 \(path)：替换了 1 处", savedPath: path, isNewFile: false))
            done.result?.change = FileChange(added: compared.added, removed: compared.removed, diff: compared.text, snapshot: "qa-snapshot",
                                             afterHash: FileChange.hash(after), wasNew: false)
            let pending = ToolCall(id: "qa-pending", name: "edit",
                                   arguments: #"{"path":"\#(path)","old_text":"100 分抵 1 元","new_text":"100 分抵 1.5 元"}"#)
            let message = Message(role: .agent, agentID: agentID, speakerName: state.agents.agent(agentID)?.displayName,
                                  text: "积分有效期改成 24 个月了，再把兑换比例调一下。", toolCalls: [done, pending], runID: UUID())
            store.append(message, to: id)
            state.chat.qaWaitForApproval(id, message: message.id, call: pending, risk: "只改 PRD 里的一行文字，影响很小。",
                                         preview: FileHistory.preview(pending, root: root))
        }
        // `-FormoraSeedInstructions YES` (10c): the open project gets an AGENTS.md — the fixtures' copy, rebuilt every run.
        if settings.bool(forKey: seedInstructionsKey), let project = currentProject {
            let url = URL(fileURLWithPath: project.folderPath).appendingPathComponent("AGENTS.md")
            try? "# 项目约定\n\n- 需求文档放在 PRD/ 下，文件名用中文。\n- 金额一律写到分。\n".write(to: url, atomically: true, encoding: .utf8)
        }
        // `-FormoraSeedApproval YES` (10b): the selected conversation waits on a command, its card offering what to
        // remember, with Bob's word on its risk; the project already remembers one command (管理项目 lists it).
        if settings.bool(forKey: seedApprovalKey), let project = currentProject, let id = state.selectedConversationID,
           let conversation = store.conversation(id), let agentID = conversation.agentID ?? conversation.members.first?.agentID {
            let call = ToolCall(id: "qa-approval", name: "bash", arguments: #"{"command":"npm test"}"#)
            let message = Message(role: .agent, agentID: agentID, speakerName: state.agents.agent(agentID)?.displayName,
                                  text: "改完了，先把测试跑一遍。", toolCalls: [call], runID: UUID())
            store.append(message, to: id)
            state.chat.qaWaitForApproval(id, message: message.id, call: call, risk: "会在项目文件夹里运行测试，只读代码、不改文件。")
            state.approvalRules.add(ApprovalGrant(kind: .command, value: "npm run lint"), project: project.id)
        }
        if settings.bool(forKey: seedBoardKey), let project = currentProject, let seeded = seedBoard(into: state, project: project.id) {
            // `-FormoraBoardConversation <name>`: another seeded chain, on the canvas and in 消息.
            let named = settings.string(forKey: boardConversationKey).flatMap { name in
                store.conversations.first { $0.groupName == name || $0.title == name }?.id
            }
            let long = settings.bool(forKey: boardLongRunKey) ? seedLongRun(into: state, project: project.id) : nil
            let id = long ?? named ?? seeded
            state.boardConversationID = id
            if named != nil || long != nil { state.selectedConversationID = id }
            if settings.bool(forKey: boardLiveKey), let conversation = store.conversation(id),
               let waiting = state.boardCards(conversation).first(where: { $0.status == .pending }) {
                state.boardFocus = waiting.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    await state.chat.qaSimulateDraft(id, agent: waiting.agentID, thinking: PerfTour.chunks(liveThinking, 3),
                                                     text: PerfTour.chunks(liveText, 3), every: .milliseconds(70))
                }
            }
            if let raw = settings.string(forKey: boardFocusKey), let index = Int(raw), let conversation = store.conversation(id) {
                let cards = state.boardCards(conversation)
                if cards.indices.contains(index) { state.boardFocus = cards[index].id }
            }
        }
        if settings.bool(forKey: seedMarkdownKey), let project = currentProject, let id = seedMarkdown(into: state, project: project.id) {
            state.selectedConversationID = id
            state.boardConversationID = id
            if settings.string(forKey: boardFocusKey) != nil, let conversation = store.conversation(id) {
                state.boardFocus = state.boardCards(conversation).first?.id
            }
        }
        switch settings.string(forKey: groupDialogKey) {
        case "create": state.groupDialog = .create
        case "settings": if let group = store.conversations.first(where: \.isGroup) { state.groupDialog = .settings(group.id) }
        default: break
        }
        if settings.bool(forKey: composerDraftKey), let id = state.selectedConversationID {
            state.composerDrafts[id] = AppState.ComposerDraft(attachments: [
                Attachment(name: "logo.png", relativePath: "site/images/logo.png", kind: .image),
                Attachment(name: "PRD.md", relativePath: "docs/PRD.md", kind: .file),
            ])
        }
        if settings.bool(forKey: reasoningMenuKey) { state.reasoningMenuFor = state.selectedConversationID }
        if let text = settings.string(forKey: composerTextKey), let id = state.selectedConversationID {
            state.composerDrafts[id, default: AppState.ComposerDraft()].text = text
        }
        // `-FormoraAwayDigest <minutes>` (9e, K): as if back after that long — what happened meanwhile.
        if let raw = settings.string(forKey: awayDigestKey), let minutes = Double(raw) {
            let project = currentProject?.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                state.showAwayDigest(since: Date.now.addingTimeInterval(-minutes * 60), project: project)
            }
        }
    }

    static let awayDigestKey = "FormoraAwayDigest"
    static let seedApprovalKey = "FormoraSeedApproval"
    static let seedInstructionsKey = "FormoraSeedInstructions"
    static let seedChangeKey = "FormoraSeedChange"
    static let seedRewindKey = "FormoraSeedRewind"
    static let seedJobsKey = "FormoraSeedJobs"
    static let seedRuleKey = "FormoraSeedRule"
    static let seedAdviceKey = "FormoraSeedAdvice"
    static let seedSideKey = "FormoraSeedSide"
    static let seedMemoryKey = "FormoraSeedMemory"
    static let seedReviewKey = "FormoraSeedReview"
    static let seedLaneCopiesKey = "FormoraSeedLaneCopies"

    /// `-FormoraSeedBoard YES` (with `-FormoraSeedAgents YES`, 8b): 「会员体系专项」, a chain with every kind of card — an
    /// assignment with its file, a hand-off, a delegation with its subtask, a branch made on the canvas still waiting —
    /// and on the board it is the one shown. `-FormoraBoardFocus 1`: that card is focused.
    static let seedBoardKey = "FormoraSeedBoard"
    static let boardFocusKey = "FormoraBoardFocus"
    static let boardConversationKey = "FormoraBoardConversation"
    /// `-FormoraBoardLongRun YES` (with `-FormoraSeedBoard YES`): 「长记录压力测试」, one card whose run has hundreds of
    /// entries — long thinking, long Markdown, steps with long outputs — to scroll 「运行过程」 through (user 2026-09-14:
    /// the panel crashed on a long run on another Mac). It is the chain shown; `-FormoraBoardFocus 0` focuses its card.
    static let boardLongRunKey = "FormoraBoardLongRun"
    /// `-FormoraBoardLive YES` (9c): the board's waiting card starts thinking and writing, as a model would, and is focused.
    static let boardLiveKey = "FormoraBoardLive"

    /// `-FormoraSeedMarkdown YES` (with `-FormoraSeedAgents YES`, D69): 「Markdown 排版样例」, a reply with every block the
    /// terminal-style rendering draws — headings, lists, a quote, inline and block code, a table, a rule — shown in 消息
    /// and on the board; with `-FormoraBoardFocus` its card is focused.
    static let seedMarkdownKey = "FormoraSeedMarkdown"

    private static func seedMarkdown(into state: AppState, project: UUID) -> UUID? {
        let store = state.conversations
        guard let design = state.agents.agents.first(where: { $0.roleID == "design" }),
              let chat = try? store.startDirect(agentID: design.id, projectID: project, blockReason: nil) else { return nil }
        store.append(Message(role: .user, text: "把会员体系的方案整理一下"), to: chat.id)
        try? store.rename(chat.id, to: "Markdown 排版样例")
        store.append(Message(role: .agent, agentID: design.id, speakerName: design.displayName, text: markdownSample,
                             usage: TokenUsage(input: 4_000, output: 900), durationSeconds: 21, runID: UUID()), to: chat.id)
        return chat.id
    }

    static let liveThinking = "用户要一份上线推广计划。先看 PRD 里三个等级的门槛和权益，再定节奏：预热一周、上线当天、之后两周复盘。渠道用站内信、短信和首页横幅。"
    static let liveText = "## 上线推广计划\n\n1. **预热**（上线前一周）：站内信告诉老用户「等级来了」\n2. **上线当天**：首页横幅 + 短信\n3. **复盘**：两周后看升级人数和复购率\n\n先写进 `docs/推广计划.md`。"

    static let markdownSample = """
    # 会员体系方案

    ## 等级
    按近 90 天消费额分三级，每月 1 日重算：

    1. 银卡：满 500 元
    2. 金卡：满 2000 元
    3. 黑卡：满 8000 元

    ### 权益
    - 生日券
      - 银卡 20 元，金卡 50 元
    - 包邮：**金卡起**
    - 专属客服

    > 保级：到期前 30 天提醒，差额补足即保级。

    | 等级 | 门槛 | 折扣 |
    | --- | --- | --- |
    | 银卡 | 500 元 | 98 折 |
    | 金卡 | 2000 元 | 95 折 |

    前端读 `GET /api/member/level`，返回：

    ```json
    { "level": "gold", "expires": "2026-12-31" }
    ```

    ---
    细节写在 PRD/会员等级体系_v1.md。
    """

    /// `-FormoraComposerText @`: the selected conversation's composer starts with this text (a group shows its `@` list).
    static let composerTextKey = "FormoraComposerText"

    private static func seedLongRun(into state: AppState, project: UUID) -> UUID? {
        let store = state.conversations
        guard let design = state.agents.agents.first(where: { $0.roleID == "design" }),
              let dev = state.agents.agents.first(where: { $0.roleID == "dev" }),
              let group = try? store.createGroup(name: "长记录压力测试", memberIDs: [design.id, dev.id], projectID: project,
                                                 reasonFor: { _ in nil }) else { return nil }
        store.append(Message(role: .user, text: "@产品设计（小设） 把会员体系的需求、方案和验收标准逐条过一遍，每一条都写清楚", assignees: [design.id]),
                     to: group.id)
        let paragraph = "会员等级按近 90 天消费额升降：银卡 500、金卡 2000、黑卡 8000，保级给 30 天缓冲；权益分折扣、积分倍率、专属客服三类，每一级递增。"
        for round in 1...60 {
            let thinking = (1...4).map { "第 \(round) 轮第 \($0) 段：" + paragraph }.joined(separator: " ")
            let text = """
            ## 第 \(round) 条：\(["等级规则", "权益", "保级", "验收标准"][round % 4])

            \(paragraph)

            - 触发：\(paragraph.prefix(30))
            - 例外：\(paragraph.suffix(30))

            ```swift
            let threshold = [500, 2000, 8000][\(round % 3)]
            ```

            | 等级 | 门槛 | 备注 |
            |---|---|---|
            | 银卡 | 500 | 第 \(round) 轮 |
            """
            let calls = (1...3).map { step in
                ToolCall(id: "long-\(round)-\(step)", name: "read", arguments: #"{"path":"PRD/会员等级体系_v1.md"}"#,
                         result: ToolResult(status: .done, output: String(repeating: paragraph + "\n", count: 6), seconds: Double(step * 3)))
            }
            store.append(Message(role: .agent, agentID: design.id, speakerName: design.displayName, text: text, thinking: thinking,
                                 usage: TokenUsage(input: 4000, output: 800), durationSeconds: 20, toolCalls: calls, runID: UUID()),
                         to: group.id)
        }
        return group.id
    }

    private static func seedBoard(into state: AppState, project: UUID) -> UUID? {
        let store = state.conversations
        func agent(_ role: String) -> AgentRecord? { state.agents.agents.first { $0.roleID == role } }
        guard let design = agent("design"), let dev = agent("dev"), let qa = agent("qa"), let ops = agent("ops"),
              let group = try? store.createGroup(name: "会员体系专项", memberIDs: [design.id, dev.id, qa.id, ops.id], projectID: project,
                                                 reasonFor: { _ in nil }) else { return nil }
        func written(_ path: String, _ id: String, seconds: Double = 2) -> ToolCall {
            ToolCall(id: id, name: "write", arguments: #"{"path":"\#(path)","content":"…"}"#,
                     result: ToolResult(status: .done, output: "已写入 \(path)", savedPath: path, isNewFile: true, seconds: seconds))
        }
        func turn(_ agent: AgentRecord, _ text: String, _ calls: [ToolCall] = [], seconds: Double, tokens: Int, id: UUID = UUID(),
                  thinking: String? = nil) -> Message {
            Message(id: id, role: .agent, agentID: agent.id, speakerName: agent.displayName, text: text, thinking: thinking,
                    usage: TokenUsage(input: tokens * 4 / 5, output: tokens / 5), durationSeconds: seconds, toolCalls: calls, runID: UUID())
        }
        let ask = Message(role: .user, text: "@产品设计（小设） 做一份会员等级体系的需求：三个等级，按近 90 天消费额升级", assignees: [design.id])
        store.append(ask, to: group.id)
        store.append(turn(design, "会员等级体系的 PRD 写好了：银卡、金卡、黑卡三级，按近 90 天消费额升降，权益和保级规则都在文件里。",
                          [ToolCall(id: "s1", name: "read", arguments: #"{"path":"PRD/购物车挽回短信提醒_v1.md"}"#,
                                    result: .done("（读到了 42 行）")), written("PRD/会员等级体系_v1.md", "s2", seconds: 12)],
                          seconds: 74, tokens: 18_400,
                          thinking: "用户要三个等级、按近 90 天消费额升级。先读购物车挽回那份 PRD 的写法，沿用它的结构：背景、等级规则、权益、保级、验收标准。门槛先按客单价估：银卡 500、金卡 2000、黑卡 8000，保级给 30 天缓冲。"),
                     to: group.id)
        let brief = "PRD 在 PRD/会员等级体系_v1.md。按它出技术方案：等级怎么算、每天几点跑、接口怎么给前端。"
        store.append(Message(role: .user, text: "〔产品设计（小设） 把接下来的工作交给了 研发（前端）〕\n\(brief)",
                             event: ThreadEvent(kind: .handoff, title: "产品设计（小设） → 研发（前端） · 第 1/6 次", detail: brief, agentID: dev.id)),
                     to: group.id)
        let devTurn = UUID()
        let link = SubtaskLink(conversationID: group.id, messageID: devTurn, callID: "s4", requesterID: dev.id, requesterName: dev.displayName,
                               readOnly: false, isCheck: false)
        let helper = store.openSubtask(projectID: project, agentID: qa.id, title: "按验收标准写测试用例", link: link)
        store.append(Message(role: .user, text: "按 PRD/会员等级体系_v1.md 的验收标准写测试用例，覆盖升级、降级、保级三条路径。"), to: helper.id)
        store.append(turn(qa, "测试用例写好了，共 18 条：升级 7 条、降级 6 条、保级 5 条，边界值都覆盖了。",
                          [written("tests/会员等级用例.md", "t1")], seconds: 41, tokens: 9_600), to: helper.id)
        var delegate = ToolCall(id: "s4", name: "delegate", arguments: #"{"to":"测试（验收）","task":"按验收标准写测试用例"}"#,
                                result: ToolResult(status: .done, output: "测试用例写好了，共 18 条：升级 7 条、降级 6 条、保级 5 条。", seconds: 41))
        delegate.subtaskID = helper.id
        store.append(turn(dev, "技术方案出来了：每天凌晨 2 点按近 90 天消费额重算等级，结果写进 member_level 表，前端读 /api/member/level。测试用例我请测试同步在写。",
                          [written("docs/tech/会员等级技术方案.md", "s3"), delegate], seconds: 126, tokens: 31_200, id: devTurn), to: group.id)
        var branch = Message(role: .user, text: "@运营（增长） 按这份 PRD 出上线推广计划", assignees: [ops.id])
        branch.boardParent = "\(ask.id)#\(design.id)"
        store.append(branch, to: group.id)
        // 「会员积分规则」 (8d, K14): a direct chat with a follow-up, pushed on from the canvas by `@` 研发 — a group now,
        // in place, its first card kept whole.
        if let direct = try? store.startDirect(agentID: design.id, projectID: project, blockReason: nil) {
            let first = Message(role: .user, text: "帮我定一下会员积分规则：怎么赚、怎么花、多久过期")
            store.append(first, to: direct.id)
            try? store.rename(direct.id, to: "会员积分规则")
            store.append(turn(design, "积分规则定好了：消费 1 元得 1 分，100 分抵 1 元，积分 12 个月后过期。",
                              [written("PRD/会员积分规则.md", "p1", seconds: 9)], seconds: 38, tokens: 7_800), to: direct.id)
            store.append(Message(role: .user, text: "过期前 7 天提醒一下用户"), to: direct.id)
            store.append(turn(design, "加上了：过期前 7 天发站内信和短信提醒。", [written("PRD/会员积分规则.md", "p2")], seconds: 12, tokens: 3_100),
                         to: direct.id)
            try? store.join(direct.id, agents: [dev.id], names: { $0 == dev.id ? dev.displayName : "" }, reasonFor: { _ in nil })
            var push = Message(role: .user, text: "@\(dev.displayName) 按这份积分规则估一下开发工作量", assignees: [dev.id])
            push.boardParent = "\(first.id)#\(design.id)"
            store.append(push, to: direct.id)
        }
        // 「会员等级上线」 (9e): Bob's arrangement — 研发 and 测试 together, each in its lane with its reply posted, 运营 after
        // both, waiting. `-FormoraBoardConversation 会员等级上线` shows it.
        if let launch = try? store.createGroup(name: "会员等级上线", memberIDs: [design.id, dev.id, qa.id, ops.id], projectID: project,
                                               reasonFor: { _ in nil }) {
            let ask = Message(role: .user, text: "@\(dev.displayName) @\(qa.displayName) @\(ops.displayName) 把会员等级上线：接口、测试和推广都安排上",
                              assignees: [dev.id, qa.id, ops.id])
            store.append(ask, to: launch.id)
            var lanes: [ThreadEvent.Arrangement.Lane] = []
            var replies: [Message] = []
            func lane(_ agent: AgentRecord, _ part: String, _ reply: String, _ call: ToolCall, seconds: Double, tokens: Int) {
                let link = SubtaskLink(conversationID: launch.id, messageID: ask.id, callID: "", requesterID: Conductor.bobID,
                                       requesterName: launch.groupName, readOnly: false, isCheck: false, lane: true)
                let run = store.openSubtask(projectID: project, agentID: agent.id, title: part, link: link)
                store.append(Message(role: .user, text: ask.text), to: run.id)
                store.append(turn(agent, reply, [call], seconds: seconds, tokens: tokens,
                                  thinking: "我负责\(part)。先读 PRD 的等级规则，再动手。"), to: run.id)
                lanes.append(.init(agentID: agent.id, subtaskID: run.id))
                var posted = Message(role: .agent, agentID: agent.id, speakerName: agent.displayName, text: reply, durationSeconds: seconds,
                                     runID: UUID())
                posted.lane = run.id
                replies.append(posted)
            }
            lane(dev, "实现会员等级接口", "接口写好了：GET /api/member/level 返回等级和到期日，单测 12 条全过。",
                 written("server/member_level.py", "l1", seconds: 21), seconds: 96, tokens: 22_400)
            lane(qa, "写接口的验收测试", "接口测试写好了：升级、降级、保级、未登录四种情况，共 16 条。",
                 written("tests/test_member_level.py", "l2", seconds: 14), seconds: 71, tokens: 15_800)
            let arrangement = ThreadEvent.Arrangement(messageID: ask.id, stages: [[dev.id, qa.id], [ops.id]], lanes: lanes)
            store.append(Message(role: .user, text: "", event: ThreadEvent(
                kind: .conduct, title: Conductor.title([[dev.displayName, qa.displayName], [ops.displayName]]), arrangement: arrangement)),
                         to: launch.id)
            for reply in replies { store.append(reply, to: launch.id) }
        }
        // 「会员权益调研」 (9e, D): two lanes side by side at the end, then Bob's summary.
        if let research = try? store.createGroup(name: "会员权益调研", memberIDs: [design.id, ops.id, dev.id], projectID: project,
                                                 reasonFor: { _ in nil }) {
            let ask = Message(role: .user, text: "@\(design.displayName) @\(ops.displayName) 调研三家竞品的会员权益，各看各的",
                              assignees: [design.id, ops.id])
            store.append(ask, to: research.id)
            var lanes: [ThreadEvent.Arrangement.Lane] = []
            var replies: [Message] = []
            for (agent, part, reply) in [
                (design, "对比权益设计", "三家都是三级会员，差异在黑卡：A 家送年度体检，B 家给专属客服，C 家只有更高的折扣。"),
                (ops, "对比拉新和留存玩法", "拉新都靠首单返券；留存上 A 家做了积分过期提醒，续费率比另外两家高约 8%。"),
            ] {
                let link = SubtaskLink(conversationID: research.id, messageID: ask.id, callID: "", requesterID: Conductor.bobID,
                                       requesterName: research.groupName, readOnly: false, isCheck: false, lane: true)
                let run = store.openSubtask(projectID: project, agentID: agent.id, title: part, link: link)
                store.append(Message(role: .user, text: ask.text), to: run.id)
                store.append(turn(agent, reply, seconds: 52, tokens: 12_600), to: run.id)
                lanes.append(.init(agentID: agent.id, subtaskID: run.id))
                var posted = Message(role: .agent, agentID: agent.id, speakerName: agent.displayName, text: reply, durationSeconds: 52, runID: UUID())
                posted.lane = run.id
                replies.append(posted)
            }
            store.append(Message(role: .user, text: "", event: ThreadEvent(
                kind: .conduct, title: Conductor.title([[design.displayName, ops.displayName]]),
                arrangement: ThreadEvent.Arrangement(messageID: ask.id, stages: [[design.id, ops.id]], lanes: lanes))), to: research.id)
            for reply in replies { store.append(reply, to: research.id) }
            let summary = """
            **结论**：三家都是三级会员，差距在黑卡权益和留存玩法。

            - **\(design.displayName)**：黑卡权益 A 家送体检、B 家给专属客服、C 家只有折扣。
            - **\(ops.displayName)**：拉新都靠首单返券；A 家的积分过期提醒让续费率高约 8%。

            **需要你定**：我们的黑卡走「服务型」（体检、客服）还是「折扣型」。
            """
            store.append(Message(role: .user, text: "〔Bob 的汇总〕\n" + summary,
                                 event: ThreadEvent(kind: .summary, title: "Bob · 汇总", detail: summary)), to: research.id)
        }
        return group.id
    }

    private static func seedConversations(into state: AppState, project: UUID) {
        let store = state.conversations
        let agents = state.agents.agents
        func agent(_ role: String) -> AgentRecord? { agents.first { $0.roleID == role } }
        guard let design = agent("design"), let dev = agent("dev") else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: -daysAgo, hour: hour, minute: minute), to: today) ?? .now
        }
        func direct(_ agent: AgentRecord, _ date: Date) -> UUID? {
            try? store.startDirect(agentID: agent.id, projectID: project, blockReason: nil, now: date).id
        }
        func user(_ id: UUID, _ text: String, _ date: Date) {
            store.append(Message(role: .user, text: text, createdAt: date), to: id)
        }
        func reply(_ id: UUID, _ agent: AgentRecord, _ text: String, _ date: Date) {
            store.append(Message(role: .agent, agentID: agent.id, speakerName: agent.displayName, text: text, createdAt: date), to: id)
        }
        // Oldest first: each new message moves its conversation to the top.
        if let ops = agent("ops"), let id = direct(ops, at(20, 10, 0)) {
            user(id, "支付链路里哪些环节掉单最多？先看最近 30 天的数据。", at(20, 10, 0))
            reply(id, ops, "最近 30 天掉单集中在两处：选择支付方式页（占 41%）和短信验证码页（占 27%）。", at(20, 10, 3))
            store.setVisibility(id, .archived)
        }
        if let id = direct(dev, at(13, 11, 20)) {
            user(id, "订单评价功能：下单后能打分和写评价，可以带图片。", at(13, 11, 20))
            reply(id, dev, "评价接口和图片上传已经写完，自测通过，改动在 services/review/。", at(13, 15, 42))
            store.setStatus(id, .done)
        }
        if let id = direct(design, at(3, 16, 40)) {
            user(id, "复购召回优惠券要不要按人群分开发？", at(3, 16, 40))
            reply(id, design, "建议分两群：近 30 天买过一次的给满减券，买过三次以上的给会员日折扣。", at(3, 16, 42))
            store.setVisibility(id, .hidden)
        }
        if let id = direct(design, at(1, 9, 30)) {
            user(id, "帮我做一个会员等级体系的需求", at(1, 9, 30))
            reply(id, design, "还差一个关键信息：等级之间的权益差异要怎么设计？", at(1, 9, 31))
        }
        if let id = direct(design, at(0, 14, 5)) {
            user(id, "帮我做一个电商网站购物车放弃挽回的需求，主要是想通过短信提醒挽回那些加购但没付款的用户", at(0, 14, 5))
            reply(id, design, "收到，这个方向很清晰。为了一次问清楚，我列几个问题：\n1. 目标用户是所有加购未付款的用户，还是特定人群？\n2. 触发条件——加购多久后发提醒？\n3. 券的规则：满减/折扣/无门槛，具体面额？\n4. 验收标准怎么定？", at(0, 14, 6))
            user(id, "所有加购未付款的注册用户；加购2小时后发；满30减8元的满减券；验收标准是短信发送成功率99%以上，点击能直接跳转回购物车", at(0, 14, 19))
            reply(id, design, "信息已经足够，我把这份 PRD 整理保存了。", at(0, 14, 22))
        }
        let members = [design, dev] + [agent("qa")].compactMap { $0 }
        if let group = try? store.createGroup(name: "购物车挽回专项", memberIDs: members.map(\.id), projectID: project,
                                             reasonFor: { _ in nil }, now: at(0, 14, 28)) {
            store.append(Message(role: .user, text: "@研发（前端） 按 PRD/cart_recovery_coupon_v1.md 出技术方案，重点是短信通道的重试和幂等",
                                 createdAt: at(0, 14, 30), assignees: [dev.id]), to: group.id)
            reply(group.id, dev, "收到。我先读 PRD，再看 services/sms 现有的通道封装，方案里会写清重试间隔和幂等键。", at(0, 14, 31))
            store.append(Message(role: .user, text: "@测试（验收） 技术方案出来后，按 PRD 里的验收标准写测试用例", createdAt: at(0, 14, 40),
                                 assignees: [members.last?.id].compactMap { $0 }), to: group.id)
            try? store.rename(group.id, to: "技术方案与接口设计")
        }
    }

    /// `-FormoraFakeLLM http://127.0.0.1:8765/v1` (with `scripts/fake-llm.py` running): a custom provider pointing at
    /// the local fake model, and every seeded Agent answering with it — streamed replies without API credit.
    static let fakeLLMKey = "FormoraFakeLLM"
    /// `-FormoraAutoReply 文字`: shortly after launch, sends that text in the selected conversation.
    static let autoReplyKey = "FormoraAutoReply"
    /// `-FormoraAutoReplyAway YES`: after sending, shows another conversation, so the reply lands unread.
    static let autoReplyAwayKey = "FormoraAutoReplyAway"
    /// `-FormoraApprovalMode alwaysAsk`: every Agent gets that 权限模式 (7b).
    static let approvalModeKey = "FormoraApprovalMode"
    /// `-FormoraContextWindow 6000`: every model's window, small enough to see compaction happen (7e).
    static let contextWindowKey = "FormoraContextWindow"
    /// `-FormoraAfterReply /cost`: once the auto-reply's run (and any compaction) is over, this command runs.
    static let afterReplyKey = "FormoraAfterReply"
    /// `-FormoraRevealCompaction YES`: a compaction's divider scrolls into view with its summary open.
    static let revealCompactionKey = "FormoraRevealCompaction"
    /// `-FormoraOpenSubtask YES`: once the auto-reply is over, its first subtask opens (7g, S8).
    static let openSubtaskKey = "FormoraOpenSubtask"
    /// `-FormoraBobAsk "文字"`: once Bob's page is open, he is asked (7h); `-FormoraBobAllow YES` answers his cards with 允许.
    static let bobAskKey = "FormoraBobAsk"
    static let bobAllowKey = "FormoraBobAllow"
    /// `-FormoraBobPanel YES`: Bob's floating panel starts open.
    static let bobPanelKey = "FormoraBobPanel"
    /// `-FormoraFakeChatGPT http://127.0.0.1:8765`: a stand-in ChatGPT sign-in against the fake server's /codex/responses;
    /// 产品设计 answers with it (7i).
    static let fakeChatGPTKey = "FormoraFakeChatGPT"
    /// `-FormoraAutoAllow YES` (7j-3): every approval card is answered 允许 about half a second after it appears.
    static let autoAllowKey = "FormoraAutoAllow"
    /// `-FormoraProbeComputer YES` (7j-3): a second after launch, what computer use can reach, written to the container's
    /// `tmp/computer-probe.txt` for a QA script to read (the old app's phase 0 probe).
    static let probeComputerKey = "FormoraProbeComputer"

    static func applyChat(to state: AppState, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault else { return }
        if let base = settings.string(forKey: fakeLLMKey),
           let provider = try? state.providers.saveCustom(CustomProviderDraft(name: "本机模拟", baseURL: base, apiProtocol: .openAICompletions,
                                                                              key: "fake-local-key"), editing: nil) {
            for agent in state.agents.agents {
                try? state.agents.saveModel(agent, AgentModelDraft(providerID: provider, modelID: "fake-prd"), isConfigured: { _ in true })
            }
            state.bobModel.choose(ModelReference(providerID: provider, modelID: "fake-prd"))
        }
        if settings.bool(forKey: probeComputerKey) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                var lines = ["trusted \(AXIsProcessTrusted())", "screen \(CGPreflightScreenCaptureAccess())",
                             "sandboxed \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)"]
                var value: CFTypeRef?
                // Finder isn't a sandboxed app; TextEdit is — the two answer differently if the target's sandbox matters.
                for bundle in ["com.apple.finder", "com.apple.TextEdit"] {
                    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
                    let app = AXUIElementCreateApplication(running.processIdentifier)
                    lines.append("\(bundle) role \(AXUIElementCopyAttributeValue(app, "AXRole" as CFString, &value).rawValue)")
                    lines.append("\(bundle) windows \(AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value).rawValue)")
                }
                if let edit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first {
                    let desktop = MacDesktop()
                    if let window = desktop.windows().first(where: { $0.pid == edit.processIdentifier }) {
                        do {
                            lines.append("tree \(AXTreeText.lines(try desktop.tree(of: window)).lines.count) lines")
                        } catch let problem as DesktopProblem {
                            lines.append("tree error \(problem.message)")
                        } catch {
                            lines.append("tree error \(error)")
                        }
                    } else {
                        lines.append("no TextEdit window in the list")
                    }
                } else {
                    lines.append("TextEdit isn't running")
                }
                lines.append("focused app \(AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), "AXFocusedApplication" as CFString, &value).rawValue)")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("computer-probe.txt")
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        }
        if settings.bool(forKey: autoAllowKey) {
            Task { @MainActor [weak state] in
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let state else { return }
                    for id in Array(state.chat.approvals.keys) { state.chat.decide(id, allow: true) }
                }
            }
        }
        if let base = settings.string(forKey: fakeChatGPTKey) {
            state.providers.chatGPTBase = base
            try? state.providers.saveChatGPT(ChatGPTCredential(access: "qa-access", refresh: "qa-refresh", expires: .now.addingTimeInterval(86_400),
                                                              accountID: "acct-qa", email: "qa@example.com", plan: "plus"))
            if let agent = state.agents.agents.first(where: { $0.roleID == "design" }) {
                try? state.agents.saveModel(agent, AgentModelDraft(providerID: ChatGPTAuth.providerID, modelID: "gpt-5.6-sol"), isConfigured: { _ in true })
            }
        }
        if let raw = settings.string(forKey: approvalModeKey), let mode = ApprovalMode(rawValue: raw) {
            for agent in state.agents.agents { try? state.agents.setApprovalMode(agent, mode) }
        }
        if let raw = settings.string(forKey: contextWindowKey), let window = Int(raw) { state.chat.contextWindow = { _ in window } }
        state.revealsCompaction = settings.bool(forKey: revealCompactionKey)
        if settings.bool(forKey: bobPanelKey) { state.bobPanelOpen = true }
        if let ask = settings.string(forKey: bobAskKey) {
            let allows = settings.bool(forKey: bobAllowKey)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                state.bobPanelOpen = true
                state.bob.send(ask)
                guard allows else { return }
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if state.bob.confirmation != nil { state.bob.decide(true) }
                    if !state.bob.isBusy { break }
                }
            }
        }
        guard let text = settings.string(forKey: autoReplyKey), let id = state.selectedConversationID else { return }
        let away = settings.bool(forKey: autoReplyAwayKey)
        let after = settings.string(forKey: afterReplyKey)
        let opensSubtask = settings.bool(forKey: openSubtaskKey)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard let conversation = state.conversations.conversation(id) else { return }
            // A command line runs as the composer runs it (7d): `/help`, `/plan 做一个会员等级体系`.
            if case .command(let command, let argument) = Commands.parse(text, roles: state.commandRoles(conversation)) {
                if let reason = await state.runCommand(command, argument: argument, in: id, projectRoot: nil, projectName: nil) {
                    state.toasts.show("\(command.name) 没有执行", note: reason, isError: true)
                }
                return
            }
            let assignees = conversation.isGroup
                ? Mentions.assignees(in: text, members: ConversationReadiness.members(of: conversation, agents: state.agents)) : []
            let sent = try? state.conversations.send(id, text: text, assignees: assignees)
            if !conversation.isGroup {
                state.chat.reply(to: id)
            } else if assignees.isEmpty {
                if let sent { state.chat.assign(id, message: sent.id) }
            } else {
                state.chat.dispatch(id, to: assignees)
            }
            if let after, case .command(let command, let argument) = Commands.parse(after, roles: state.commandRoles(conversation)) {
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !state.chat.isRunning(id), state.chat.compacting[id] == nil { break }
                }
                if let reason = await state.runCommand(command, argument: argument, in: id, projectRoot: nil, projectName: nil) {
                    state.toasts.show("\(command.name) 没有执行", note: reason, isError: true)
                }
            }
            if opensSubtask {
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !state.chat.isRunning(id) { break }
                }
                state.selectedConversationID = state.conversations.subtasks(of: id).first?.id ?? id
            }
            guard away, let project = state.conversations.conversation(id)?.projectID else { return }
            state.selectedConversationID = state.conversations.list(project: project, hiddenView: false).first { $0.id != id }?.id
        }
    }

    /// `-FormoraSeedHooks YES`: a global hooks.json — a PreToolUse check that writes stay in PRD/, a PostToolUse note,
    /// a Stop post to the local fake server's `/hook` — and a project one waiting for 启用 (7b′).
    static let seedHooksKey = "FormoraSeedHooks"
    /// `-FormoraSeedImage YES`: a drawn picture at `附件/首页截图.png` in the open project, for an Agent to read (7j-1).
    static let seedImageKey = "FormoraSeedImage"
    /// `-FormoraOpenToolCards YES`: tool cards start open, so their output and pictures show (7j-1).
    static let openToolCardsKey = "FormoraOpenToolCards"
    static var opensToolCards: Bool { UserDefaults.standard.bool(forKey: openToolCardsKey) }
    /// `-FormoraHookEditor add`: the hook editor opens; `editProject`: on the open project's first hook (its lower half,
    /// with no tool section, fits without scrolling).
    static let hookEditorKey = "FormoraHookEditor"

    static func applyHooks(to state: AppState, projectRoot: URL?, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault else { return }
        if settings.bool(forKey: seedHooksKey) {
            var global = HookFile()
            global.add(HookHandler(kind: .command(#"grep -q '"path":"PRD/' || { echo "只能写到 PRD/ 目录下" >&2; exit 2; }"#)),
                       event: .preToolUse, matcher: "write")
            global.add(HookHandler(kind: .command(#"cat > /dev/null; mkdir -p .formora && date +%H:%M >> .formora/hook.log; echo '{"systemMessage":"Hook：这次写入已记进 .formora/hook.log"}'"#)),
                       event: .postToolUse, matcher: "write|edit")
            global.add(HookHandler(kind: .http(url: "http://127.0.0.1:8765/hook", format: .feishu)), event: .stop, matcher: nil)
            try? state.hooks.save(global, to: .global)
            if let projectRoot {
                // Written straight to the file, not through the form: it waits for 启用.
                var project = HookFile()
                project.add(HookHandler(kind: .command("echo 项目背景：面向中小电商商家，短信通道用阿里云。")), event: .sessionStart, matcher: nil)
                let url = HookStore.projectURL(projectRoot)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? project.encoded().write(to: url)
                state.hooks.reload()
            }
        }
        if settings.bool(forKey: seedImageKey), let projectRoot {
            let url = projectRoot.appendingPathComponent("\(ConversationStore.attachmentsFolder)/首页截图.png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? samplePicture()?.write(to: url)
        }
        switch settings.string(forKey: hookEditorKey) {
        case "add":
            state.hookEditor = .add(.global)
        case "editProject":
            if let projectRoot, let entry = state.hooks.file(.project(projectRoot)).entries.first {
                state.hookEditor = .edit(HookTarget(scope: .project(projectRoot), entry: entry))
            }
        default:
            break
        }
    }

    /// A home page sketched in blocks: a dark bar, a banner, three cards.
    private static func samplePicture() -> Data? {
        let width = 900, height = 560
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        func fill(_ rect: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(rect)
        }
        fill(CGRect(x: 0, y: 0, width: width, height: height), 0.96, 0.96, 0.97)
        fill(CGRect(x: 0, y: height - 64, width: width, height: 64), 0.12, 0.13, 0.16)
        fill(CGRect(x: 40, y: height - 250, width: width - 80, height: 150), 0.55, 0.58, 0.97)
        for index in 0..<3 {
            let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.98, 0.72, 0.36), (0.35, 0.78, 0.55), (0.93, 0.42, 0.45)]
            fill(CGRect(x: 40 + index * 280, y: 60, width: 260, height: 190), colors[index].0, colors[index].1, colors[index].2)
        }
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func applyOverlay(to state: AppState, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault, let raw = settings.string(forKey: overlayKey) else { return }
        switch raw {
        case "projectMenu": state.projectMenu = .list
        case "newProjectMenu": state.projectMenu = .newProject
        case "manage": state.isManagingProjects = true
        case "launchNewProject": state.launchStartsOnNewProject = true
        // The cold start's steps (9f).
        case "launchModel": state.launchStartsOnStep = .model
        case "launchAgent": state.launchStartsOnStep = .agent
        case "launchReady": state.launchStartsOnStep = .ready
        default: break
        }
    }
}
