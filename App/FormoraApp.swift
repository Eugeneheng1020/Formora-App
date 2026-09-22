import AppKit
import SwiftData
import SwiftUI

@main
struct FormoraApp: App {
    @State private var state: AppState
    @State private var session: ProjectSession
    private let container: ModelContainer
    private let initialMode: WindowShaper.Mode
    private let isDefaultProfile: Bool

    init() {
        FontRegistry.registerBundledFonts()
        let profile = AppProfile.current
        // The Developer ID build left the sandbox (7j, B1′): this profile's data comes over from the container, once.
        SandboxMigration.run(profile)
        let secrets = KeychainSecretStore(service: profile.keychainServiceName(KeychainSecretStore.baseService))
        let mcpSecrets = KeychainSecretStore(service: profile.keychainServiceName(MCPStore.baseService))
        if !profile.isDefault, UserDefaults.standard.bool(forKey: AppProfile.resetDefaultsKey) {
            try? profile.reset()
            secrets.deleteAll()
            mcpSecrets.deleteAll()
        }

        do {
            let storeURL = try profile.applicationSupportDirectory().appendingPathComponent(ProjectStore.storeFileName)
            container = try ProjectStore.makeContainer(storeURL: storeURL)
        } catch {
            fatalError("Formora could not open its data store: \(error)")
        }
        let store = ProjectStore(container: container, defaults: profile.makeUserDefaults())
        VerificationHooks.seedProjects(into: store, profile: profile)
        let session = ProjectSession(store: store, picker: VerificationHooks.folderPicker(for: profile))

        let support = try? profile.applicationSupportDirectory()
        // What the user opens and edits — Skills, hooks, memories, MCP — lives in ~/.formora (user 2026-09-14); an earlier
        // version's comes over once.
        let resources = UserResources.directory(for: profile)
        if let support, let resources { UserResources.migrate(from: support, to: resources) }
        let places = UserResources.places(support: support, directory: resources)
        let account = AccountStore(defaults: profile.makeUserDefaults(),
                                   folder: support?.appendingPathComponent("Account", isDirectory: true))
        let providers = ProviderStore(secrets: secrets, fileURL: support?.appendingPathComponent(ProviderConfig.fileName))
        VerificationHooks.seedAccount(account, profile: profile)
        VerificationHooks.seedProviderKeys(into: providers, profile: profile)

        let agents = AgentStore(container: container, avatarFolder: support?.appendingPathComponent("Agents", isDirectory: true))
        let skills = SkillLibrary(folder: places.skills,
                                  builtInFolder: Bundle.main.url(forResource: "Skills", withExtension: nil),
                                  defaults: profile.makeUserDefaults())
        skills.installBuiltIns()
        // The subagents (user 2026-09-15): the three shipped ones written to ~/.formora/agents/ once.
        let subagents = SubagentLibrary(globalFolder: places.agents)
        subagents.installBuiltIns()
        let mcp = MCPStore(secrets: mcpSecrets, fileURL: places.mcp)
        // A stdio server starts in the open project's folder (9d, S2).
        mcp.projectRoot = { [weak session] in session?.accessibleRoot }
        let conversations = ConversationStore(folder: support?.appendingPathComponent(ConversationStore.folderName, isDirectory: true))
        let notificationSettings = NotificationSettings(defaults: profile.makeUserDefaults())
        let hooks = HookStore(folder: places.hooks)
        let state = AppState(account: account, providers: providers, agents: agents, skills: skills, mcp: mcp,
                             conversations: conversations, notifications: notificationSettings, hooks: hooks,
                             memory: MemoryStore(folder: places.memory),
                             bobModel: BobModel(defaults: profile.makeUserDefaults()),
                             approvalRules: ApprovalRuleStore(fileURL: support?.appendingPathComponent(ApprovalRuleStore.fileName)),
                             prices: ModelPriceStore(fileURL: support?.appendingPathComponent(ModelPriceStore.fileName)),
                             subagents: subagents, defaults: profile.makeUserDefaults())
        // Replies still streaming are kept as stopped, and background writes land, before the process goes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                state.chat.stopAll()
                conversations.flush()
                // stdio servers go with Formora (9d, S4).
                mcp.stdio.stopAllNow()
            }
        }
        // Away a while and back: one sentence on what happened meanwhile (9e, K).
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { state.wentAway() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { state.cameBack(project: session.current?.id) }
        }
        Self.connectAlerts(state, settings: notificationSettings, quiet: !profile.isDefault)
        // The system prompt names the project a conversation belongs to (7a).
        state.chat.projectName = { [weak session] id in session?.projects.first { $0.id == id }?.name }
        // 10d: files as they were before an Agent wrote them, for 撤销 — outside every project.
        state.chat.fileHistoryFolder = support?.appendingPathComponent("FileHistory", isDirectory: true)
        // D96: the files the user hands Bob — Formora's own folder, not a project's.
        state.bob.attachmentsFolder = support?.appendingPathComponent(BobAttachments.folderName, isDirectory: true)
        // 10l: the copies members working side by side work in — Formora's own folder; one left by a crash goes now.
        let laneCopies = support?.appendingPathComponent("LaneCopies", isDirectory: true)
        if let laneCopies { try? FileManager.default.removeItem(at: laneCopies) }
        state.chat.laneCopiesFolder = laneCopies
        // The tools work in the conversation's project folder — the one open now, whose access is held (7b).
        state.chat.projectRoot = { [weak session] id in session?.current?.id == id ? session?.accessibleRoot : nil }
        // Computer use (7j, C1–C3): the Mac itself, where screenshots go, and the bar that stops it.
        if ComputerBuild.isAvailable {
            state.chat.desktop = MacDesktop()
            state.chat.screenshotFolder = support?.appendingPathComponent("Screenshots", isDirectory: true)
            let brake = ComputerGuard()
            brake.onStop = { [weak state] id in
                if id == BobSession.operatingID { state?.bob.stop() } else { state?.chat.stop(id) }
            }
            state.chat.onOperating = { id, operating in brake.set(id, operating: operating) }
            // D97: Bob on the same Mac, behind the same bar.
            state.bob.desktop = state.chat.desktop
            state.bob.screenshotFolder = support?.appendingPathComponent("Screenshots/Bob", isDirectory: true)
            state.bob.onOperating = { operating in brake.set(BobSession.operatingID, operating: operating) }
        }
        // 2026-09-14: the app's own log (seven days), the diagnostic bundle's sources, and Sparkle for the user's copy.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let logFolder = AppLog.folder(profileName: profile.name)
        // Not under XCTest: the unit tests host the app and must never reach the feed, show an update, or write the
        // user's log.
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        if !underTests { AppLog.shared.start(folder: logFolder, redact: { SecretShield.shared.redact($0) }, version: "\(version) (\(build))") }
        state.diagnosticSources = DiagnosticSources(
            logs: logFolder, conversations: support?.appendingPathComponent(ConversationStore.folderName, isDirectory: true),
            exportFolder: profile.isDefault ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                : support?.appendingPathComponent("Diagnostics", isDirectory: true),
            profileName: profile.name)
        let feedOverride = UserDefaults.standard.string(forKey: AppUpdater.feedKey)
        if !underTests, profile.isDefault || feedOverride != nil { state.updater = AppUpdater(feedOverride: feedOverride) }
        // `-FormoraCheckUpdate YES` (QA): press 检查更新 two seconds in, so Sparkle's window can be screenshotted.
        if !underTests, UserDefaults.standard.bool(forKey: "FormoraCheckUpdate") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                state.updater?.check()
            }
        }
        // User 2026-09-17: conversations gone quiet are looked over for what the memory missed — a minute after the
        // start (the ones that went quiet while the app was closed), then every five. The user's own profile only.
        if !underTests, profile.isDefault {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                while !Task.isCancelled {
                    await state.chat.sweepMemory()
                    try? await Task.sleep(for: .seconds(300))
                }
            }
        }
        if let section = VerificationHooks.initialSection(for: profile) { state.select(section) }
        VerificationHooks.applyOverlay(to: state, profile: profile)
        VerificationHooks.applySettings(to: state, profile: profile)
        VerificationHooks.applyAgents(to: state, currentProject: session.current, profile: profile)
        VerificationHooks.applyMCP(to: state, profile: profile)
        VerificationHooks.applyMessages(to: state, currentProject: session.current, profile: profile)
        VerificationHooks.applyChat(to: state, profile: profile)
        VerificationHooks.applyFilesChat(to: state, currentProject: session.current, profile: profile)
        VerificationHooks.applyHooks(to: state, projectRoot: session.accessibleRoot, profile: profile)
        PerfTour.startIfAsked(state: state, session: session, profile: profile)

        _state = State(initialValue: state)
        _session = State(initialValue: session)
        initialMode = session.current == nil ? .launch : .main
        isDefaultProfile = profile.isDefault
    }

    /// Sound and banners for replies the user didn't see, and clicking a banner opens the conversation.
    /// Named profiles stay quiet: a QA run must never make macOS ask the user for permission or play sounds.
    private static func connectAlerts(_ state: AppState, settings: NotificationSettings, quiet: Bool) {
        guard !quiet else { return }
        let notifier = SystemNotifier(settings: settings)
        notifier.onOpen = { [weak state] id in state?.openConversation(id) }
        state.checkNotificationPermission = { request in
            Task {
                if request { await notifier.requestPermission() } else { await notifier.refreshPermission() }
            }
        }
        state.budgetAlert = { id, body in notifier.post(title: "用量超过了预算", body: body, conversationID: id) }
        state.replyAlert = { [weak state] conversation, message in
            guard let state else { return }
            if state.notifications.sound { NSSound(named: "Glass")?.play() }
            let headline = ConversationReadiness.headline(of: conversation, agents: state.agents)
            // A reply that never came (user 2026-09-15: 任务中断要提醒): in front, a toast; away, a notification.
            if let interruption = message.interruption, NSApplication.shared.isActive {
                state.toasts.show("\(headline)：没有回复", note: interruption, isError: true)
                return
            }
            guard state.notifications.desktop, !NSApplication.shared.isActive else { return }
            let body = message.interruption.map { "没有回复：\($0)" } ?? String(message.text.prefix(120))
            notifier.post(title: headline, body: body, conversationID: conversation.id)
        }
    }

    var body: some Scene {
        // A single window: the app is one workspace, not a document per window.
        Window("Formora", id: "main") {
            AppRootView(state: state, session: session, initialMode: initialMode,
                        remembersWindowFrame: isDefaultProfile)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(initialMode == .launch ? LaunchMetrics.windowSize : ShellMetrics.defaultWindowSize)
        .windowResizability(.contentMinSize)
        .commands {
            // 2026-09-14: the app menu's 检查更新…, as every Sparkle app has it.
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { state.updater?.check() }.disabled(state.updater == nil)
            }
        }
    }
}
