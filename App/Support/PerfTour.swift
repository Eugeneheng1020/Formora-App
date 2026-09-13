import AppKit
import SwiftUI

/// The main thread's busy spans, per scenario (9a, P1): from the run loop waking to it going back to sleep. A span past
/// 50 ms is a stall the user can feel, past 100 ms a visible one, past 250 ms a hang.
@MainActor
final class HitchMonitor {
    struct Stats {
        var spans = 0
        var over50 = 0
        var over100 = 0
        var over250 = 0
        var longest = 0.0
    }

    private(set) var stats: [String: Stats] = [:]
    private(set) var order: [String] = []
    /// When each scenario ran, wall clock: a profiler's samples are matched to them (`scripts/perf-profile.sh`).
    private(set) var windows: [(name: String, start: Date, end: Date)] = []
    var scenario = "启动" {
        didSet {
            guard scenario != oldValue else { return }
            windows.append((oldValue, since, .now))
            since = .now
        }
    }
    private var since = Date.now
    private var observer: CFRunLoopObserver?
    private var woke = CFAbsoluteTimeGetCurrent()

    func start() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.note(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }

    private func note(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        guard activity == .beforeWaiting else {
            woke = now
            return
        }
        let milliseconds = (now - woke) * 1000
        if stats[scenario] == nil { order.append(scenario) }
        var entry = stats[scenario, default: Stats()]
        entry.spans += 1
        entry.longest = max(entry.longest, milliseconds)
        if milliseconds > 50 { entry.over50 += 1 }
        if milliseconds > 100 { entry.over100 += 1 }
        if milliseconds > 250 { entry.over250 += 1 }
        stats[scenario] = entry
    }

    /// One line per scenario run: name, then its start and end as Unix seconds.
    func windowsText() -> String {
        windows.map { "\($0.name)\t\($0.start.timeIntervalSince1970)\t\($0.end.timeIntervalSince1970)" }.joined(separator: "\n") + "\n"
    }

    /// A Markdown table, one row per scenario in the order they ran.
    func report() -> String {
        var lines = ["| 场景 | 主线程忙了几次 | 超过 50ms | 超过 100ms | 超过 250ms | 最长 (ms) |", "|---|---|---|---|---|---|"]
        for name in order {
            guard let entry = stats[name] else { continue }
            lines.append("| \(name) | \(entry.spans) | \(entry.over50) | \(entry.over100) | \(entry.over250) | \(Int(entry.longest.rounded())) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// `-FormoraPerfTour <report path>` in a named profile (9a, P1): seeds a 300-message thread, 60 conversations and a
/// 30-card board, walks through every place a stall would be felt — switching, scrolling with real scroll-wheel events,
/// a reply streaming in, the board's pan / zoom / pointer, file previews, the settings pages — writes what the main
/// thread did in each, and quits. Run it with `scripts/perf-tour.sh`.
@MainActor
enum PerfTour {
    static let tourKey = "FormoraPerfTour"

    struct Seeds {
        let long: UUID
        let writer: UUID
        let others: [UUID]
        let board: UUID?
    }

    static func startIfAsked(state: AppState, session: ProjectSession, profile: AppProfile, settings: UserDefaults = .standard) {
        guard !profile.isDefault, let path = settings.string(forKey: tourKey), let project = session.current,
              let seeds = seed(state, project: project.id) else { return }
        let monitor = HitchMonitor()
        monitor.start()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await run(state: state, session: session, seeds: seeds, monitor: monitor)
            monitor.stop()
            try? monitor.windowsText().write(toFile: path + ".windows.tsv", atomically: true, encoding: .utf8)
            try? monitor.report().write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    // MARK: Seeds

    static func seed(_ state: AppState, project: UUID) -> Seeds? {
        let store = state.conversations
        func agent(_ role: String) -> AgentRecord? { state.agents.agents.first { $0.roleID == role } }
        guard let design = agent("design"), let dev = agent("dev"), let qa = agent("qa"), let ops = agent("ops"),
              let long = try? store.startDirect(agentID: design.id, projectID: project, blockReason: nil) else { return nil }
        func reply(_ who: AgentRecord, _ text: String, _ calls: [ToolCall] = []) -> Message {
            Message(role: .agent, agentID: who.id, speakerName: who.displayName, text: text, usage: TokenUsage(input: 3_000, output: 600),
                    durationSeconds: 14, toolCalls: calls, runID: UUID())
        }
        func written(_ path: String, _ index: Int) -> ToolCall {
            ToolCall(id: "w\(index)", name: "write", arguments: #"{"path":"\#(path)","content":"…"}"#,
                     result: ToolResult(status: .done, output: "已写入 \(path)", savedPath: path, isNewFile: index % 2 == 0, seconds: 3))
        }
        // 300 messages; every third reply a PRD-sized Markdown body with two steps.
        try? store.rename(long.id, to: "长对话（性能）")
        for index in 0..<150 {
            store.append(Message(role: .user, text: "第 \(index + 1) 轮：把会员体系的方案再细化一点，特别是第 \(index % 7 + 1) 节"), to: long.id)
            if index % 3 == 0 {
                let read = ToolCall(id: "r\(index)", name: "read", arguments: #"{"path":"PRD/会员.md"}"#, result: .done("（读到了 120 行）"))
                store.append(reply(design, VerificationHooks.markdownSample, [read, written("PRD/会员_v\(index).md", index)]), to: long.id)
            } else {
                store.append(reply(design, "第 \(index + 1) 轮改好了：补充了保级规则和降级的缓冲期，**金卡**的门槛从 2000 调到 1800，理由写在第 \(index % 7 + 1) 节。\n\n还有两个问题等你拍板：\n- 黑卡要不要邀请制\n- 积分和等级是否挂钩"),
                             to: long.id)
            }
        }
        var others: [UUID] = []
        for index in 0..<60 {
            let who = [design, dev, qa, ops][index % 4]
            guard let chat = try? store.startDirect(agentID: who.id, projectID: project, blockReason: nil) else { continue }
            store.append(Message(role: .user, text: "需求 \(index + 1)：做一个小功能，写清楚验收标准"), to: chat.id)
            store.append(reply(who, "需求 \(index + 1) 的方案写好了，放在 docs/需求\(index + 1).md。"), to: chat.id)
            others.append(chat.id)
        }
        let board = try? store.createGroup(name: "性能看板", memberIDs: [design.id, dev.id, qa.id, ops.id], projectID: project,
                                           reasonFor: { _ in nil })
        if let board {
            let pairs = [(design, dev), (qa, ops), (dev, qa), (design, ops)]
            for index in 0..<15 {
                let (first, second) = pairs[index % pairs.count]
                store.append(Message(role: .user, text: "@\(first.displayName) @\(second.displayName) 第 \(index + 1) 项：看一下这部分",
                                     assignees: [first.id, second.id]), to: board.id)
                store.append(reply(first, "第 \(index + 1) 项 \(first.displayName) 看过了，结论在文件里。", [written("docs/看板\(index)-a.md", index)]),
                             to: board.id)
                store.append(reply(second, "第 \(index + 1) 项 \(second.displayName) 也看过了。", [written("docs/看板\(index)-b.md", index + 1)]),
                             to: board.id)
            }
        }
        return Seeds(long: long.id, writer: design.id, others: others, board: board?.id)
    }

    // MARK: The tour

    static func run(state: AppState, session: ProjectSession, seeds: Seeds, monitor: HitchMonitor) async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? window.frame.size
        // Window coordinates (origin bottom-left): the thread in the detail column, the list beside the rail.
        let threadPoint = CGPoint(x: (size.width + 365) / 2, y: size.height / 2)
        let listPoint = CGPoint(x: 215, y: size.height / 2)

        let sectionNames: [AppSection: String] = [.messages: "消息", .agents: "Agent", .board: "看板", .files: "文件", .settings: "设置"]
        for _ in 0..<3 {
            for section in [AppSection.messages, .agents, .board, .files, .settings] {
                monitor.scenario = "切换到「\(sectionNames[section] ?? "")」"
                state.select(section)
                await pause(0.5)
            }
        }
        monitor.scenario = "切换对话"
        state.select(.messages)
        for id in seeds.others.prefix(10) {
            state.selectedConversationID = id
            await pause(0.4)
        }
        monitor.scenario = "打开 300 条的长对话"
        state.selectedConversationID = seeds.long
        await pause(2)
        monitor.scenario = "长对话滚动"
        await scroll(window, at: threadPoint, steps: 120, delta: 60)
        await scroll(window, at: threadPoint, steps: 120, delta: -60)
        monitor.scenario = "流式回复（长对话里）"
        await state.chat.qaSimulateDraft(seeds.long, agent: seeds.writer, thinking: chunks(thinkingSample, 6),
                                         text: chunks(VerificationHooks.markdownSample, 4), every: .milliseconds(25))
        await pause(0.5)
        monitor.scenario = "对话列表滚动"
        await scroll(window, at: listPoint, steps: 100, delta: -50)
        await scroll(window, at: listPoint, steps: 100, delta: 50)
        monitor.scenario = "打开 30 张卡的看板"
        state.select(.board)
        if let board = seeds.board { state.selectBoardConversation(board) }
        await pause(2)
        monitor.scenario = "看板平移缩放"
        for step in 0..<60 {
            BoardViewport.active?.panBy(step < 30 ? -8 : 8, step % 2 == 0 ? 4 : -4)
            await pause(0.016)
        }
        for step in 0..<40 {
            BoardViewport.active?.zoom(by: step < 20 ? 1.02 : 0.98, at: CGPoint(x: 600, y: 400))
            await pause(0.016)
        }
        monitor.scenario = "看板上移动鼠标"
        for step in 0..<150 {
            BoardViewport.active?.pointer = CGPoint(x: 300 + Double(step * 4), y: 300 + Double(step % 40) * 5)
            await pause(0.012)
        }
        BoardViewport.active?.pointer = nil
        if let board = seeds.board, let conversation = state.conversations.conversation(board) {
            for (index, card) in state.boardCards(conversation).prefix(6).enumerated() {
                monitor.scenario = index == 0 ? "看板第一次点开卡片" : "看板换一张卡片"
                state.boardFocus = card.id
                await pause(0.6)
            }
            monitor.scenario = "看板关掉运行过程"
            state.boardFocus = nil
            await pause(0.6)
        }
        monitor.scenario = "切到「文件」"
        state.select(.files)
        await pause(0.8)
        for path in sampleFiles(session.accessibleRoot) {
            monitor.scenario = "文件预览 · \(path.hasPrefix("large/") ? "大文件 " : "")\((path as NSString).pathExtension)"
            await state.files?.reveal(relativePath: path)
            await pause(0.8)
        }
        state.select(.settings)
        for category in SettingsCategory.allCases {
            monitor.scenario = "设置 · \(category.title)"
            state.settingsCategory = category
            await pause(0.5)
        }
        monitor.scenario = "结束"
    }

    /// Real scroll-wheel events, delivered to the window at `point` (window coordinates): the window reads the
    /// event's location as its own, and a window-less event's location is its screen point.
    static func scroll(_ window: NSWindow, at point: CGPoint, steps: Int, delta: Int32) async {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        for _ in 0..<steps {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.location = CGPoint(x: point.x, y: screenHeight - point.y)
            if let wheel = NSEvent(cgEvent: event) { window.sendEvent(wheel) }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// One file of each kind in the project, the large ones among them.
    static func sampleFiles(_ root: URL?) -> [String] {
        guard let root else { return [] }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var picked: [String: String] = [:]
        for url in FileTools.files(under: root) {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            let kind = relative.hasPrefix("large/") ? "large:" + url.pathExtension : url.pathExtension.lowercased()
            if picked[kind] == nil { picked[kind] = relative }
        }
        return Array(picked.values.sorted().prefix(12))
    }

    static func chunks(_ text: String, _ size: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count == size {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static let thinkingSample = """
    用户要细化会员体系。先看现有 PRD 的等级划分：银卡、金卡、黑卡三级，按近 90 天消费额。需要补的是保级规则、降级缓冲期，\
    还有积分和等级是否挂钩。保级：到期前 30 天提醒，差额补足即保级；降级给 30 天缓冲。金卡门槛 2000 可能偏高，看数据再定。
    """
}
