import SwiftUI

/// First-launch flow (`launch-flow-v1.html`, then the cold start — user 2026-09-09, 9f): choose or create a project;
/// then, when something isn't set up yet, a model, a first Agent and a word on where to start — each skippable, each
/// already done skipped by itself. Only shown when there is no project to reopen. The window is the card; every screen
/// has the same size. The project opens at the very end, so quitting half way lands back here, not in a window where
/// nothing can run.
struct LaunchFlowView: View {
    let state: AppState
    let session: ProjectSession
    let onEnterMain: () -> Void

    private enum Screen: Equatable {
        case choice
        case newProject
        case model, agent, ready
        case opening(name: String, isNew: Bool, done: Bool)
    }

    @State private var screen: Screen
    /// What the cold start has to do, as it was when the flow began.
    @State private var setup: LaunchSetup
    /// The project chosen or made, held until the end (9f).
    @State private var pending: ProjectRecord?
    @State private var isNew = false
    /// What the steps set up, for the last one.
    @State private var providerName: String?
    @State private var agentName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState, session: ProjectSession, onEnterMain: @escaping () -> Void) {
        self.state = state
        self.session = session
        self.onEnterMain = onEnterMain
        _setup = State(initialValue: LaunchSetup.current(providers: state.providers, agents: state.agents))
        let start: Screen = switch state.launchStartsOnStep {
        case .model: .model
        case .agent: .agent
        case .ready: .ready
        case .project, nil: state.launchStartsOnNewProject ? .newProject : .choice
        }
        _screen = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            LaunchBackdrop()
            content
                .padding(.horizontal, LaunchMetrics.horizontalPadding)
                .padding(.vertical, LaunchMetrics.verticalPadding)
                .frame(width: LaunchMetrics.windowSize.width, height: LaunchMetrics.windowSize.height,
                       alignment: isTopAligned ? .top : .center)
        }
        .frame(width: LaunchMetrics.windowSize.width, height: LaunchMetrics.windowSize.height)
    }

    private var isTopAligned: Bool {
        switch screen {
        case .newProject, .model, .agent: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .choice:
            choiceScreen
        case .newProject:
            newProjectScreen
        case .model:
            ModelSetupStep(state: state, onDone: { name in
                providerName = name
                go(setup.next(after: .model))
            }, onSkip: { go(setup.next(after: .model)) })
        case .agent:
            AgentSetupStep(state: state, projectID: pending?.id, onDone: { name in
                agentName = name
                go(setup.next(after: .agent))
            }, onSkip: { go(setup.next(after: .agent)) })
        case .ready:
            ReadyStep(projectName: pending?.name,
                      providerName: providerName ?? state.providers.entries.first { state.providers.hasKey($0.id) }?.name,
                      agentName: agentName ?? state.agents.agents.first?.displayName,
                      onStart: finish)
        case let .opening(name, isNew, done):
            openingScreen(name: name, isNew: isNew, done: done)
        }
    }

    // MARK: Screen 1 — choose

    private var choiceScreen: some View {
        VStack(spacing: 0) {
            // Something to set up after this: the four steps show from the first (9f).
            if setup.isGuided { SetupProgress(step: LaunchSetup.Step.project.rawValue).padding(.bottom, 34) }
            Text("F")
                .font(FormoraFont.ui(21, weight: 800))
                .foregroundStyle(Palette.accentInk.color)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.accent.color))
                .padding(.bottom, 22)
                .accessibilityHidden(true)
            Text("欢迎使用 Formora")
                .font(FormoraFont.ui(21, weight: 700))
                .tracking(-0.21)
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, 8)
                .accessibilityIdentifier("launch.title")
            Text("选择一个已有项目，或者新建一个项目开始")
                .font(FormoraFont.ui(13))
                .foregroundStyle(Palette.inkMuted.color)
                .multilineTextAlignment(.center)
                .padding(.bottom, 30)
            VStack(spacing: 10) {
                LaunchActionRow(icon: Icons.files, title: "打开已有项目", detail: "从 Finder 选择一个项目文件夹",
                                identifier: "launch.openExisting", action: openExisting)
                LaunchActionRow(icon: Icons.plus, title: "新建项目", detail: "创建一个新的项目文件夹",
                                identifier: "launch.newProject") { screen = .newProject }
            }
        }
    }

    private func openExisting() {
        guard let record = session.pickExistingProject() else { return }
        chosen(record, isNew: false)
    }

    // MARK: Screen 2 — new project

    private var newProjectScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("新建项目")
                .font(FormoraFont.ui(21, weight: 700))
                .tracking(-0.21)
                .foregroundStyle(Palette.ink.color)
                .padding(.bottom, 24)
            NewProjectForm(layout: .launch, session: session,
                           onCancel: { screen = .choice },
                           onCreated: { _ in },
                           onRegistered: { chosen($0, isNew: true) })
        }
    }

    // MARK: The cold start (9f)

    private func chosen(_ record: ProjectRecord, isNew: Bool) {
        pending = record
        self.isNew = isNew
        go(setup.next(after: .project))
    }

    private func go(_ step: LaunchSetup.Step?) {
        switch step {
        case .project: screen = .choice
        case .model: screen = .model
        case .agent: screen = .agent
        case .ready: screen = .ready
        case nil: finish()
        }
    }

    /// The project opens now, at the end. (A step opened directly for a screenshot has none held: the first known.)
    private func finish() {
        guard let record = pending ?? session.projects.first else { return screen = .choice }
        session.open(record)
        beginOpening(name: record.name, isNew: isNew)
    }

    // MARK: Opening

    private func beginOpening(name: String, isNew: Bool) {
        screen = .opening(name: name, isNew: isNew, done: false)
        let spin = reduceMotion ? 0 : 450
        let hold = reduceMotion ? 150 : 650
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(spin))
            screen = .opening(name: name, isNew: isNew, done: true)
            try? await Task.sleep(for: .milliseconds(hold))
            onEnterMain()
        }
    }

    private func openingScreen(name: String, isNew: Bool, done: Bool) -> some View {
        VStack(spacing: 0) {
            if done {
                IconView(Icons.check, size: 24)
                    .foregroundStyle(Palette.success.color)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Palette.successSoft.color))
                    .padding(.bottom, 20)
            } else {
                Spinner().padding(.bottom, 20)
            }
            openingText(name: name, isNew: isNew, done: done)
                .font(FormoraFont.ui(14))
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launch.opening")
    }

    private func openingText(name: String, isNew: Bool, done: Bool) -> Text {
        var quoted = AttributedString("「\(name)」")
        quoted.foregroundColor = Palette.ink.color
        quoted.font = FormoraFont.ui(14, weight: 600)
        func muted(_ s: String) -> AttributedString {
            var a = AttributedString(s)
            a.foregroundColor = Palette.inkMuted.color
            return a
        }
        let verb = isNew ? "创建并打开" : "打开"
        return done ? Text(quoted + muted("已\(verb)")) : Text(muted("正在\(verb)") + quoted + muted("…"))
    }
}

/// `.launch-action`: icon tile, title + description, trailing chevron; the whole row is the button.
private struct LaunchActionRow: View {
    let icon: SVGIcon
    let title: String
    let detail: String
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconView(icon, size: 20)
                    .foregroundStyle(Palette.accent.color)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.accentSoft.color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(FormoraFont.ui(14, weight: 600)).foregroundStyle(Palette.ink.color)
                    Text(detail).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color)
                }
                Spacer(minLength: 0)
                IconView(Icons.chevronRight, size: 16).foregroundStyle(Palette.inkFaint.color)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? Palette.surfaceRaised2.color : Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isHovering ? Palette.lineStrong.color : Palette.line.color, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// `.opening-spinner`: 34pt ring in `--line-strong` with an accent arc. Static under Reduce Motion.
private struct Spinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Palette.lineStrong.color, lineWidth: 3)
            Circle().trim(from: 0, to: 0.25).stroke(Palette.accent.color, lineWidth: 3)
                .rotationEffect(.degrees(angle))
        }
        .frame(width: 34, height: 34)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { angle = 360 }
        }
    }
}
