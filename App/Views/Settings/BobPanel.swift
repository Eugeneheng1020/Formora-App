import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bob's way in (7h, B1; spec §8.8): a 46pt round button at the bottom-right of 设置, on every category; it opens a
/// 380-wide bubble with his conversation over the page you are on — you say 「接入 Notion」 looking at the MCP list, and
/// the result lands on that list behind it. Leaving 设置 hides both (RootView closes the panel).
struct BobFloat: View {
    let state: AppState
    let session: ProjectSession
    /// 540, or less when the window is short (spec: 100vh − 130).
    let panelHeight: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if state.bobPanelOpen {
                BobPanel(state: state, height: max(panelHeight, 300))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { state.bobPanelOpen.toggle() }
            } label: {
                IconView(Icons.robot, size: 20)
                    .foregroundStyle(state.bobPanelOpen ? Palette.accentInk.color : Palette.inkMuted.color)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(state.bobPanelOpen ? Palette.accent.color : Palette.surfaceRaised.color))
                    .overlay(Circle().strokeBorder(state.bobPanelOpen ? Palette.accent.color : Palette.line.color, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Bob")
            .accessibilityLabel(state.bobPanelOpen ? "收起 Bob" : "打开 Bob")
            .accessibilityIdentifier("bob.fab")
        }
        .padding(.trailing, 24)
        .padding(.bottom, 24)
        .onAppear(perform: syncProject)
        .onChange(of: session.current?.id) { syncProject() }
    }

    /// The project he looks at: the one open in the window.
    private func syncProject() {
        state.bob.project = session.current.map { BobSession.Project(id: $0.id, name: $0.name, root: session.accessibleRoot) }
    }
}

/// The bubble (spec §8.8, mockup `.assistant-panel`): the head with 清空对话 and 关闭, the log, the input. The user's
/// words on the right in a bubble, Bob's on the left in plain text; each change on its card (B5) and its result with
/// the way to see it (B6).
private struct BobPanel: View {
    let state: AppState
    let height: CGFloat

    private var bob: BobSession { state.bob }
    private var model: ModelReference? { state.bobModel.current(state.providers) }

    var body: some View {
        VStack(spacing: 0) {
            head
            Rectangle().fill(Palette.line.color).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    log
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: bob.entries) { scroll(proxy) }
                .onChange(of: bob.draft) { scroll(proxy) }
                .onChange(of: bob.confirmation) { scroll(proxy) }
                .onAppear { scroll(proxy) }
            }
            Rectangle().fill(Palette.line.color).frame(height: 1)
            BobInput(state: state, isEnabled: model != nil)
                .padding(.vertical, 11)
                .padding(.horizontal, 12)
        }
        .frame(width: 380, height: height)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The shape casts the shadow, not the log (9a): a shadow of the content was redrawn with every streamed word.
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface.color).shadow(color: .black.opacity(0.4), radius: 28, y: 12))
        .onExitCommand { state.bobPanelOpen = false }
        // D96: files dropped anywhere on the panel go with the next message.
        .dropDestination(for: URL.self) { urls, _ in
            guard model != nil, !bob.isBusy else { return false }
            Task { await bob.attach(urls) }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.panel")
    }

    private var head: some View {
        HStack(spacing: 8) {
            IconView(Icons.robot, size: 15).foregroundStyle(Palette.accent.color)
            Text("Bob")
                .font(FormoraFont.ui(13, weight: 700))
                .foregroundStyle(Palette.ink.color)
            if let model {
                Text(model.modelID)
                    .font(FormoraFont.mono(10.5))
                    .foregroundStyle(Palette.inkFaint.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !bob.entries.isEmpty {
                IconActionButton(icon: Icons.trash, label: "清空对话", identifier: "bob.clear") { bob.clear() }
                    .disabled(bob.isBusy)
            }
            IconActionButton(icon: Icons.close, label: "关闭", identifier: "bob.close") { state.bobPanelOpen = false }
        }
        .padding(.vertical, 10)
        .padding(.leading, 16)
        .padding(.trailing, 10)
    }

    @ViewBuilder private var log: some View {
        VStack(alignment: .leading, spacing: 12) {
            if bob.entries.isEmpty, !bob.isBusy {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model == nil ? BobSession.noModel : BobSession.hint(state.bobModel.approvalMode))
                        .font(FormoraFont.ui(12))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if model == nil {
                        Button("去选模型") { state.settingsCategory = .bob }
                            .buttonStyle(FormoraButtonStyle())
                    } else {
                        // What to ask (user 2026-09-13): the cards on his page, by kind; a click asks. A question that
                        // needs a file stays on the cards, where 问 Bob leaves it in the input for the file.
                        ForEach(BobExample.Group.allCases) { group in
                            let items = BobExamples.all.filter { $0.group == group && $0.attachment == nil }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.title)
                                        .font(FormoraFont.ui(10.5, weight: 600))
                                        .foregroundStyle(Palette.inkFaint.color)
                                    ForEach(items) { example in
                                        Button { bob.send(example.question) } label: {
                                            Text(example.question)
                                                .font(FormoraFont.ui(12))
                                                .foregroundStyle(Palette.inkMuted.color)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 7)
                                                .padding(.horizontal, 11)
                                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surfaceRaised.color))
                                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("bob.suggestion")
                                    }
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                }
            }
            ForEach(bob.entries) { entry in
                BobEntryView(state: state, entry: entry)
            }
            if !bob.draft.isEmpty {
                MarkdownText(source: bob.draft)
            } else if bob.isBusy, bob.confirmation == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(bob.running == nil ? "Bob 正在想…" : "正在执行…")
                        .font(FormoraFont.ui(11.5))
                        .foregroundStyle(Palette.inkFaint.color)
                }
            }
            Color.clear.frame(height: 1).id("bottom")
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

/// A turn: the user's words on the right in a bubble; Bob's on the left in plain text, his steps under them.
private struct BobEntryView: View {
    let state: AppState
    let entry: BobSession.Entry

    var body: some View {
        switch entry.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(FormoraFont.ui(12.5))
                        .foregroundStyle(Palette.ink.color)
                        .textSelection(.enabled)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                        .frame(maxWidth: 270, alignment: .trailing)
                        .accessibilityIdentifier("bob.user")
                }
                // D96: the files that went with it.
                if !entry.attachments.isEmpty {
                    Text("附件：" + entry.attachments.map(\.name).joined(separator: "、"))
                        .font(FormoraFont.mono(10.5))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineLimit(2)
                        .frame(maxWidth: 270, alignment: .trailing)
                        .accessibilityIdentifier("bob.userAttachments")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .bob:
            VStack(alignment: .leading, spacing: 8) {
                if !entry.text.isEmpty {
                    MarkdownText(source: entry.text).accessibilityIdentifier("bob.reply")
                }
                ForEach(entry.steps) { step in
                    BobStepCard(state: state, step: step)
                }
                if let failure = entry.failure {
                    Text(failure)
                        .font(FormoraFont.ui(12))
                        .foregroundStyle(Palette.alert.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bob.failure")
                }
                if let note = entry.note {
                    Text(note)
                        .font(FormoraFont.ui(11))
                        .foregroundStyle(Palette.inkFaint.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One step Bob takes: what it does, its state; the card asking for 允许 while it waits (B5); its result (B6).
private struct BobStepCard: View {
    let state: AppState
    let step: BobSession.Step

    private var waiting: BobSession.Confirmation? {
        state.bob.confirmation.flatMap { $0.callID == step.call.id ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                IconView(icon, size: 12).foregroundStyle(Palette.inkMuted.color)
                Text(step.call.summary)
                    .font(FormoraFont.mono(11))
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                status
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            if let waiting {
                VStack(alignment: .leading, spacing: 9) {
                    // The line above already names the step: here, what exactly it touches.
                    Text((waiting.detail.isEmpty ? waiting.summary : waiting.detail) + "。你点「允许」才会做。")
                        .font(FormoraFont.ui(11.5))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("bob.confirmText")
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button("不用了") { state.bob.decide(false) }
                            .buttonStyle(FormoraButtonStyle(kind: .ghost))
                            .accessibilityIdentifier("bob.deny")
                        Button("允许") { state.bob.decide(true) }
                            .buttonStyle(FormoraButtonStyle(kind: .primary))
                            .accessibilityIdentifier("bob.allow")
                    }
                }
                .padding(.top, 1)
                .padding(.bottom, 10)
                .padding(.horizontal, 10)
            }
            // Undone, the file isn't what the card says any more: only the line below speaks for it.
            if let card = step.card, step.result?.change?.undone != true {
                BobResultCard(result: card, undo: card.memory == nil ? nil : { state.bob.undoMemory(step: step.id) }) { go(card.jump) }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            // D95: what a write or an edit changed, and the way back.
            if let result = step.result, let change = result.change, let path = result.savedPath {
                BobChangeLine(state: state, stepID: step.id, path: path, change: change)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(waiting != nil ? Palette.accent.color : Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.step.\(step.call.name)")
    }

    private var icon: SVGIcon {
        switch step.call.name {
        case "formora_help", "read", "fetch": Icons.file
        case "glob", "grep", "web_search", "formora_state": Icons.search
        case "mcp_catalog", "mcp_add": Icons.plug
        case let name where name.hasPrefix(MCPTools.prefix): Icons.plug
        case "skill_create", "skill": Icons.sparkle
        case "folder_create": Icons.files
        case "notification_set": Icons.bell
        case "open_url": Icons.arrowUpRight
        case "write", "edit": Icons.pencil
        case "bash": Icons.terminal
        case "remember", "memory_clear": Icons.bulb
        default: Icons.chip
        }
    }

    @ViewBuilder private var status: some View {
        if let result = step.result {
            switch result.status {
            case .done: label("完成", Palette.success.color)
            case .failed: label("失败", Palette.alert.color)
            case .denied: label("没同意", Palette.inkMuted.color)
            case .stopped: label("已停止", Palette.inkFaint.color)
            }
        } else if waiting != nil {
            label("等你确认", Palette.accent.color)
        } else if state.bob.running == step.call.id {
            ProgressView().controlSize(.mini)
        } else {
            label("排队中", Palette.inkFaint.color)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text).font(FormoraFont.ui(10.5, weight: 600)).foregroundStyle(color)
    }

    /// A settings page keeps the panel open over it; 文件 leaves 设置, and the panel closes (spec §8.8).
    private func go(_ jump: BobResult.Jump?) {
        switch jump {
        case .settings(let category):
            state.settingsCategory = category
        case .file(let path):
            state.select(.files)
            Task { await state.files?.reveal(relativePath: path) }
        case nil:
            break
        }
    }
}

/// Under a step that wrote a file (D95): what changed, 撤销 while the file is still what Bob wrote, then 已撤销.
private struct BobChangeLine: View {
    let state: AppState
    let stepID: String
    let path: String
    let change: FileChange
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(change.undone == true ? "已撤销：\(path) 回到了修改之前" : "改了 \(path)（+\(change.added) −\(change.removed) 行）")
                    .font(FormoraFont.mono(10.5))
                    .foregroundStyle(Palette.inkFaint.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("bob.change")
                Spacer(minLength: 6)
                if change.undone != true, FileHistory.canUndo(change) {
                    Button("撤销") { problem = state.bob.undo(stepID) }
                        .buttonStyle(FormoraButtonStyle(kind: .ghost))
                        .disabled(state.bob.isBusy)
                        .accessibilityIdentifier("bob.undo")
                }
            }
            if let problem {
                Text(problem)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.alert.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `.assistant-result`: a check, the title, the mono meta line, and the way to see it.
private struct BobResultCard: View {
    let result: BobResult
    /// A memory card's 撤销 (user 2026-09-17).
    var undo: (() -> Void)?
    let go: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                IconView(Icons.check, size: 13).foregroundStyle(Palette.success.color)
                Text(result.title)
                    .font(FormoraFont.ui(12, weight: 600))
                    .foregroundStyle(Palette.ink.color)
            }
            Text(result.meta)
                .font(FormoraFont.mono(10.5))
                .foregroundStyle(Palette.inkFaint.color)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if result.jump != nil {
                Button(result.jumpLabel, action: go)
                    .buttonStyle(FormoraButtonStyle())
                    .padding(.top, 4)
                    .accessibilityIdentifier("bob.go")
            }
            if let undo {
                if result.memoryUndone {
                    Text("已撤销").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color).padding(.top, 2)
                        .accessibilityIdentifier("bob.memory.undone")
                } else {
                    Button("撤销", action: undo)
                        .buttonStyle(FormoraButtonStyle())
                        .padding(.top, 4)
                        .accessibilityIdentifier("bob.memory.undo")
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.result")
    }
}

/// The input: Return sends, 停止 while he works. Typing only redraws the send button (spec §8.8).
/// One thing 「/」 offers: one of his commands, or a Skill to ask for.
private struct BobSuggestion: Identifiable {
    let name: String
    let note: String
    let command: BobCommand?

    var id: String { name }
}

/// The input (D96): 「/」 lists his commands and every Skill; the paperclip, ⌘V or a drop on the panel add files, a
/// video is cut into frames before it can go. Return sends, 停止 while he works.
private struct BobInput: View {
    let state: AppState
    let isEnabled: Bool
    @State private var selection = 0
    @State private var height: CGFloat = 24
    @State private var isFocused = false

    private var bob: BobSession { state.bob }

    private var canSend: Bool {
        isEnabled && !bob.isBusy && bob.preparing == 0
            && (!bob.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !bob.pending.isEmpty)
    }

    /// While the first word after 「/」 is being typed.
    private var suggestions: [BobSuggestion] {
        let text = bob.input
        guard isEnabled, text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let query = String(text.dropFirst())
        let needle = FileSearch.normalize(query)
        let commands = BobCommands.matching(query).map { BobSuggestion(name: $0.name, note: $0.note, command: $0) }
        let skills = state.skills.skills
            .filter { needle.isEmpty || FileSearch.normalize("skill:\($0.id) \($0.name)").contains(needle) }
            .map { BobSuggestion(name: "/skill:\($0.id)", note: $0.name, command: nil) }
        return Array((commands + skills).prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty { popup }
            if !bob.pending.isEmpty { chips }
            HStack(alignment: .bottom, spacing: 9) {
                IconActionButton(icon: Icons.paperclip, label: "添加附件", identifier: "bob.attach") { pickFiles() }
                    .disabled(!isEnabled || bob.isBusy)
                field
                sendButton
            }
        }
        .opacity(isEnabled ? 1 : 0.55)
    }

    /// The main composer's text view: a SwiftUI field's editor keeps ⌘V to itself, so a picture would never arrive.
    private var field: some View {
        ComposerTextView(text: Binding(get: { bob.input }, set: { bob.input = $0 }), height: $height, isFocused: $isFocused,
                         isEditable: isEnabled && !bob.isBusy,
                         placeholder: isEnabled ? "让 Bob 帮你做点什么…　/ 指令" : "先给 Bob 选一个模型",
                         identifier: "bob.input", onSubmit: submit,
                         onPasteImage: { bob.attachPasted($0) },
                         onPasteFiles: { urls in Task { await bob.attach(urls) } },
                         onMentionKey: key, listOpen: { !suggestions.isEmpty }, fontSize: 12.5)
            .frame(height: min(max(height, 24), 110))
            .onChange(of: bob.input) { selection = 0 }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
            .accessibilityIdentifier("bob.input")
    }

    private var popup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                Button { accept(item) } label: {
                    HStack(spacing: 8) {
                        Text(item.name).font(FormoraFont.mono(11.5)).foregroundStyle(Palette.ink.color).lineLimit(1)
                        Text(item.note).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 9)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(index == selection ? Palette.surfaceRaised.color : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bob.suggest.\(item.name)")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.suggestions")
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(bob.pending) { item in
                    HStack(spacing: 5) {
                        IconView(item.kind == .image ? Icons.image : item.kind == .video ? Icons.display : Icons.file, size: 11)
                        Text(item.name).font(FormoraFont.mono(10.5)).lineLimit(1)
                        if item.kind == .video, item.duration == nil, bob.preparing > 0 { ProgressView().controlSize(.mini) }
                        Button { bob.removePending(item.id) } label: { IconView(Icons.close, size: 9) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除 \(item.name)")
                    }
                    .foregroundStyle(Palette.inkMuted.color)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Palette.surfaceRaised.color))
                    .overlay(Capsule().strokeBorder(Palette.line.color, lineWidth: 1))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("bob.attachment")
                }
            }
        }
    }

    /// ↑ ↓ walk the open list and Return or Tab takes the highlighted line; `false` leaves the key to the text.
    private func key(_ key: MentionKey) -> Bool {
        let items = suggestions
        guard !items.isEmpty else { return false }
        switch key {
        case .up: selection = (selection - 1 + items.count) % items.count
        case .down: selection = (selection + 1) % items.count
        case .accept: accept(items[min(selection, items.count - 1)])
        case .cancel: bob.input = ""
        }
        return true
    }

    /// Return: the highlighted suggestion while the list is open, otherwise send.
    private func submit() {
        let items = suggestions
        if items.indices.contains(selection) {
            accept(items[selection])
        } else if canSend {
            perform(bob.sendInput())
        }
    }

    /// A command runs at once; a Skill waits for what to do with it.
    private func accept(_ item: BobSuggestion) {
        if item.command != nil {
            bob.input = item.name
            perform(bob.sendInput())
        } else {
            bob.input = item.name + " "
        }
    }

    /// What a command leaves to the panel.
    private func perform(_ action: BobCommand.Action?) {
        switch action {
        case .dump:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bob.transcript(), forType: .string)
            state.toasts.show("已复制和 Bob 的对话")
        case .export:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = "和 Bob 的对话.html"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try Data(bob.exportHTML().utf8).write(to: url, options: .atomic)
                state.toasts.show("已导出", note: url.lastPathComponent)
            } catch {
                state.toasts.show("没有导出", note: error.localizedDescription, isError: true)
            }
        case .go(let category):
            state.settingsCategory = category
        default:
            break
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "给 Bob 的附件"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await bob.attach(urls) }
    }

    private var sendButton: some View {
            Button {
                if bob.isBusy { bob.stop() } else { perform(bob.sendInput()) }
            } label: {
                IconView(state.bob.isBusy ? Icons.close : Icons.send, size: 14)
                    .foregroundStyle(Palette.accentInk.color)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Palette.accent.color))
                    .opacity(state.bob.isBusy || canSend ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .disabled(!state.bob.isBusy && !canSend)
            .accessibilityLabel(state.bob.isBusy ? "停止" : "发送")
            .accessibilityIdentifier(state.bob.isBusy ? "bob.stop" : "bob.send")
    }
}
