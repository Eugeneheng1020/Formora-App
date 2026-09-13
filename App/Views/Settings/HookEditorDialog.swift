import SwiftUI

/// 添加 / 编辑 Hook (7b′, H3): where it applies, the moment, which tools, a command or a URL, the timeout — saved into
/// the hooks.json it belongs to. 试一下 runs it once with a sample event. The scrim doesn't close it; Esc and ✕ do.
struct HookEditorDialog: View {
    let state: AppState
    let session: ProjectSession
    let target: HookEditorTarget

    private enum Form: Hashable {
        case command, url
    }

    private enum Trial: Equatable {
        case running
        case done(String, isError: Bool)
    }

    /// The tools a hook can be matched to, as the product names them; the list shows the same words.
    static let tools: [(name: String, label: String)] = [
        ("read", "读取"), ("glob", "查找"), ("grep", "搜索"), ("write", "写入"), ("edit", "修改"),
        ("bash", "运行命令"), ("web_search", "搜索网络"), ("fetch", "读网页"), ("open_url", "打开网址"),
    ]

    @State private var scope: HookStore.Scope = .global
    @State private var event: HookEvent = .postToolUse
    @State private var matcher = ""
    @State private var form: Form = .command
    @State private var command = ""
    @State private var url = ""
    @State private var format: WebhookFormat = .feishu
    @State private var timeout = ""
    @State private var problem: String?
    @State private var trial: Trial?

    private var editing: HookTarget? {
        if case .edit(let target) = target { return target }
        return nil
    }

    private var root: URL? { session.accessibleRoot }

    /// Where a command runs: the scope's project, else the open one.
    private var workingFolder: URL? {
        if case .project(let folder) = scope { return folder }
        return root
    }

    var body: some View {
        ZStack {
            Palette.scrim.color.ignoresSafeArea().contentShape(Rectangle()).onTapGesture {}
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("HOOK").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
                        Text(editing == nil ? "添加 Hook" : "编辑 Hook")
                            .font(FormoraFont.ui(18, weight: 700)).foregroundStyle(Palette.ink.color)
                            .accessibilityIdentifier("hookEditor.title")
                        Text("到了选定的时机，自动运行一条命令，或往一个网址发一条消息。")
                            .font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color)
                    }
                    Spacer(minLength: 0)
                    IconActionButton(icon: Icons.close, label: "关闭", identifier: "hookEditor.close", action: close)
                }
                .padding(.top, 22)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                Rectangle().fill(Palette.line.color).frame(height: 1)
                ScrollView {
                    // Three questions, one after another (user 2026-09-12: the form was cramped and messy).
                    VStack(alignment: .leading, spacing: 24) {
                        section("在哪里生效") { scopePicker }
                        section("什么时候") {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                ForEach(HookEvent.allCases, id: \.self) { option in
                                    MomentCard(event: option, isOn: option == event) { event = option }
                                }
                            }
                            .accessibilityIdentifier("hookEditor.event")
                            hint(event.note)
                        }
                        if event.usesToolMatcher {
                            section("对哪些工具") {
                                FlowLayout(spacing: 6) {
                                    ToolChip(label: "全部工具", isOn: isAllTools) { matcher = "" }
                                    ForEach(Self.tools, id: \.name) { tool in
                                        ToolChip(label: tool.label, isOn: selectedTools.contains(tool.name)) { toggle(tool.name) }
                                    }
                                }
                                InputField(placeholder: "其他工具：直接写工具名，多个用 | 分隔，比如 mcp__docs__search", text: $matcher, mono: true,
                                           identifier: "hookEditor.matcher")
                            }
                        }
                        section("做什么") {
                            SegmentedControl(options: [(Form.command, "运行命令"), (.url, "发到网址")], selection: $form, identifier: "hookEditor.form")
                            if form == .command {
                                FormoraTextEditor(placeholder: "比如：cat > /dev/null; npx prettier --write PRD", text: $command, height: 84,
                                                  metrics: .detail, identifier: "hookEditor.command")
                                hint("在项目文件夹里用 bash 运行。事件信息以 JSON 从标准输入传入（和 Claude Code 相同）；退出码 2 表示拦下，理由写到标准错误。")
                            } else {
                                InputField(placeholder: "https://open.feishu.cn/open-apis/bot/v2/hook/…", text: $url, mono: true,
                                           identifier: "hookEditor.url")
                                SegmentedControl(options: WebhookFormat.allCases.map { ($0, $0.shortLabel) }, selection: $format,
                                                 identifier: "hookEditor.format")
                                hint(format == .raw
                                     ? "把事件信息整个作为 JSON 发过去，给自己写的服务用。"
                                     : "发一条文字消息，写明哪个 Agent 在哪个任务里做了什么。机器人地址在群设置的「机器人」里复制。")
                            }
                            HStack(spacing: 8) {
                                Text("超时").font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color)
                                InputField(placeholder: "\(event.defaultTimeout)", text: $timeout, identifier: "hookEditor.timeout")
                                    .frame(width: 90)
                                Text("秒，留空按 \(event.defaultTimeout) 秒").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
                            }
                            .padding(.top, 2)
                        }
                        if let problem { InlineError(text: problem, identifier: "hookEditor.problem") }
                        if let trial { trialView(trial) }
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 26)
                }
                .frame(maxHeight: 600)
                Rectangle().fill(Palette.line.color).frame(height: 1)
                HStack(spacing: 9) {
                    Button(trial == .running ? "运行中…" : "试一下") { runTrial() }
                        .buttonStyle(FormoraButtonStyle(kind: .ghost))
                        .disabled(trial == .running)
                        .accessibilityIdentifier("hookEditor.try")
                    Spacer(minLength: 0)
                    Button("取消", action: close).buttonStyle(FormoraButtonStyle(kind: .ghost))
                    Button("保存") { save() }
                        .buttonStyle(FormoraButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("hookEditor.save")
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.color))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .modalShadow()
            .background {
                Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("hookEditor")
        }
        .onAppear(perform: load)
        .onChange(of: event) { problem = nil }
        .onChange(of: form) { problem = nil; trial = nil }
    }

    // MARK: Parts

    @ViewBuilder private var scopePicker: some View {
        if let editing {
            Text(editing.scope == .global ? "全局" : "当前项目")
                .font(FormoraFont.ui(12.5)).foregroundStyle(Palette.ink.color)
        } else if let root, let project = session.current {
            SegmentedControl(options: [(HookStore.Scope.global, "全局"), (.project(root), "当前项目 · \(project.name)")],
                             selection: $scope, identifier: "hookEditor.scope")
            hint(scope == .global ? "存进 Formora 的全局 hooks.json，所有项目都生效。"
                                  : "存进这个项目的 .formora/hooks.json，只在这个项目里生效，可以跟项目一起分享。")
        } else {
            Text("全局（没有打开项目时只能加全局 Hook）").font(FormoraFont.ui(12.5)).foregroundStyle(Palette.ink.color)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(FormoraFont.ui(11.5))
            .foregroundStyle(Palette.inkFaint.color)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func trialView(_ trial: Trial) -> some View {
        let (text, isError): (String, Bool) = {
            if case let .done(text, isError) = trial { return (text, isError) }
            return ("正在运行…", false)
        }()
        return Text(text)
            .font(FormoraFont.mono(11))
            .foregroundStyle(isError ? Palette.alert.color : Palette.inkMuted.color)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
            .accessibilityIdentifier("hookEditor.trial")
    }

    // MARK: Tools

    private var isAllTools: Bool {
        let trimmed = matcher.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "*"
    }

    private var selectedTools: Set<String> {
        Set(matcher.split(whereSeparator: { $0 == "|" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    /// Chips rewrite the matcher; names they don't know stay.
    private func toggle(_ name: String) {
        var parts = matcher.split(whereSeparator: { $0 == "|" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "*" }
        if let index = parts.firstIndex(where: { $0.lowercased() == name }) {
            parts.remove(at: index)
        } else {
            parts.append(name)
        }
        let order = Self.tools.map(\.name)
        parts.sort { (order.firstIndex(of: $0.lowercased()) ?? .max) < (order.firstIndex(of: $1.lowercased()) ?? .max) }
        matcher = parts.joined(separator: "|")
    }

    // MARK: Loading, checking, saving

    private func load() {
        guard let editing else {
            scope = .global
            return
        }
        scope = editing.scope
        event = editing.entry.known ?? .postToolUse
        matcher = editing.entry.matcher ?? ""
        timeout = editing.entry.handler.timeout.map(String.init) ?? ""
        switch editing.entry.handler.kind {
        case .command(let text):
            form = .command
            command = text
        case let .http(address, kind):
            form = .url
            url = address
            format = kind
        case .unsupported:
            break
        }
    }

    /// The hook as the form says, or `nil` with the problem shown.
    private func checked() -> HookHandler? {
        problem = nil
        var seconds: Int?
        let rawTimeout = timeout.trimmingCharacters(in: .whitespaces)
        if !rawTimeout.isEmpty {
            guard let value = Int(rawTimeout), (1...600).contains(value) else {
                problem = "超时要填 1 到 600 之间的整数（秒）"
                return nil
            }
            seconds = value
        }
        var handler = editing?.entry.handler ?? HookHandler(kind: .command(""))
        switch form {
        case .command:
            let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                problem = "命令不能为空"
                return nil
            }
            handler.kind = .command(text)
        case .url:
            let address = url.trimmingCharacters(in: .whitespaces)
            guard let parsed = URL(string: address), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
                problem = "网址要以 https:// 开头"
                return nil
            }
            handler.kind = .http(url: address, format: format)
        }
        handler.timeout = seconds
        return handler
    }

    private func save() {
        guard let handler = checked() else { return }
        let matcher = event.usesToolMatcher ? matcher : nil
        var file = state.hooks.file(scope)
        if let editing {
            file.replace(editing.entry, with: handler, event: event, matcher: matcher)
        } else {
            file.add(handler, event: event, matcher: matcher)
        }
        do {
            try state.hooks.save(file, to: scope)
            state.hookEditor = nil
            state.toasts.show("已保存", note: "「\(event.label)」的 Hook 已\(editing == nil ? "添加" : "更新")", seconds: 2)
        } catch {
            problem = "没有保存：\(error.localizedDescription)"
        }
    }

    /// Once, with a sample event of the chosen moment; what came back and what it would mean.
    private func runTrial() {
        guard let handler = checked() else { return }
        trial = .running
        let input = sampleInput
        let folder = workingFolder
        let event = event
        let seconds = handler.timeout ?? event.defaultTimeout
        Task {
            switch handler.kind {
            case .command(let text):
                let run = await HookEngine.runCommand(text, input: input.json, cwd: folder, timeout: TimeInterval(seconds),
                                                      environment: HookEngine.environment(projectPath: folder?.path, event: event))
                let outcome = HookEngine.interpret(run, event: event, name: handler.name, timeout: seconds, plainIsContext: true)
                trial = .done(Self.describe(run, outcome), isError: run.failure != nil || run.timedOut || (run.exit != 0 && run.exit != 2))
            case let .http(address, kind):
                let run = await HookEngine.post(address, body: kind.body(input), headers: handler.headers, timeout: TimeInterval(seconds))
                let text = run.failure ?? (run.timedOut ? "超过 \(seconds) 秒没有回应" : "发送成功，去机器人所在的群里看看")
                trial = .done(text, isError: run.failure != nil || run.timedOut)
            case .unsupported:
                trial = nil
            }
        }
    }

    private static func describe(_ run: HookEngine.Execution, _ outcome: HookOutcome) -> String {
        var lines = [run.timedOut ? "超过时间，被停下了" : run.failure ?? "退出码 \(run.exit.map(String.init) ?? "?")"]
        let output = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { lines.append("输出：\(output.prefix(300))") }
        let errors = run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errors.isEmpty { lines.append("错误输出：\(errors.prefix(300))") }
        if let blocked = outcome.blocked {
            lines.append("结果：会拦下，理由「\(blocked)」")
        } else if let permission = outcome.permission {
            lines.append("结果：\(permission == .allow ? "直接放行这一步" : permission == .deny ? "不允许这一步" : "要你确认这一步")")
        } else if !outcome.context.isEmpty {
            lines.append("结果：输出会作为背景交给 Agent")
        } else if run.exit == 0 {
            lines.append("结果：不改变什么，照常进行")
        }
        return lines.joined(separator: "\n")
    }

    /// A sample of the chosen moment, plainly marked as a test (a robot will post it).
    private var sampleInput: HookInput {
        var input = HookInput(event: event, conversationID: UUID(), title: "Hook 测试", projectPath: workingFolder?.path,
                              projectName: session.current?.name, agentName: "产品设计（测试）", agentRole: "design",
                              permissionMode: ApprovalMode.write.rawValue,
                              message: "Formora Hook 测试：这是「\(event.label)」的一条示例消息")
        switch event {
        case .preToolUse, .postToolUse:
            input.toolName = "write"
            input.toolInput = ##"{"content":"# 示例","path":"PRD/示例.md"}"##
            input.toolUseID = "call_test"
            if event == .postToolUse { input.toolResponse = "已写入 PRD/示例.md（新建，9 字节）" }
        case .userPromptSubmit:
            input.prompt = "帮我写一份会员体系的需求"
        case .stop, .subagentStop:
            input.lastAssistantMessage = "PRD 已经写好了。"
        case .sessionStart, .subagentStart:
            break
        }
        return input
    }

    private func close() {
        state.hookEditor = nil
    }
}

/// One moment to pick (user 2026-09-12: seven in a segmented row wrapped their words): its name and a line on it.
private struct MomentCard: View {
    let event: HookEvent
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.label)
                    .font(FormoraFont.ui(12.5, weight: 600))
                    .foregroundStyle(isOn ? Palette.accent.color : Palette.ink.color)
                Text(event.short)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isOn ? Palette.accentSoft.color : Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOn ? Palette.accent.color : Palette.line.color, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hookEditor.moment.\(event.rawValue)")
    }
}

extension HookEvent {
    /// A line under the moment's name in the form.
    var short: String {
        switch self {
        case .sessionStart: "新对话第一次交给 Agent 之前"
        case .userPromptSubmit: "你发出一条消息的时候"
        case .preToolUse: "Agent 调用工具之前，可以拦下"
        case .postToolUse: "工具执行成功之后"
        case .stop: "Agent 一轮回复完"
        case .subagentStart: "委派的子任务开始之前"
        case .subagentStop: "委派的子任务回复完"
        }
    }
}

private struct ToolChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(FormoraFont.ui(11.5, weight: isOn ? 600 : 400))
                .foregroundStyle(isOn ? Palette.accent.color : Palette.inkMuted.color)
                .padding(.horizontal, 11)
                .frame(minHeight: 26)
                .background(Capsule().fill(isOn ? Palette.accentSoft.color : Palette.surfaceRaised2.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hookEditor.tool.\(label)")
    }
}

extension WebhookFormat {
    /// Short enough for the segmented control.
    var shortLabel: String {
        switch self {
        case .raw: "原样 JSON"
        case .feishu: "飞书"
        case .wecom: "企业微信"
        case .dingtalk: "钉钉"
        case .slack: "Slack"
        }
    }
}
