import SwiftUI

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
                    Text(model == nil ? BobSession.noModel : BobSession.hint)
                        .font(FormoraFont.ui(12))
                        .foregroundStyle(Palette.inkMuted.color)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    if model == nil {
                        Button("去选模型") { state.settingsCategory = .bob }
                            .buttonStyle(FormoraButtonStyle())
                    } else {
                        ForEach(BobSession.suggestions, id: \.self) { suggestion in
                            Button { bob.send(suggestion) } label: {
                                Text(suggestion)
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
            Text(entry.text)
                .font(FormoraFont.ui(12.5))
                .foregroundStyle(Palette.ink.color)
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                .frame(maxWidth: 270, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("bob.user")
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
                    Text((waiting.detail.isEmpty ? waiting.summary : waiting.detail) + "。Bob 改东西之前都要你点允许。")
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
            if let card = step.card {
                BobResultCard(result: card) { go(card.jump) }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
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
        case "skill_create": Icons.sparkle
        case "folder_create": Icons.files
        case "notification_set": Icons.bell
        case "open_url": Icons.arrowUpRight
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

/// `.assistant-result`: a check, the title, the mono meta line, and the way to see it.
private struct BobResultCard: View {
    let result: BobResult
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
private struct BobInput: View {
    let state: AppState
    let isEnabled: Bool

    private var canSend: Bool { isEnabled && !state.bob.isBusy && !state.bob.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            TextField(isEnabled ? "让 Bob 帮你做点什么…" : "先给 Bob 选一个模型",
                      text: Binding(get: { state.bob.input }, set: { state.bob.input = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(FormoraFont.ui(12.5))
                .lineLimit(1...5)
                .onSubmit { if canSend { state.bob.send(state.bob.input) } }
                .disabled(!isEnabled || state.bob.isBusy)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                .accessibilityIdentifier("bob.input")
            Button {
                if state.bob.isBusy { state.bob.stop() } else { state.bob.send(state.bob.input) }
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
        .opacity(isEnabled ? 1 : 0.55)
    }
}
