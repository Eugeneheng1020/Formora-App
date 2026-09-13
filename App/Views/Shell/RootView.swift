import AppKit
import SwiftUI

/// The main window: rail | list | detail, with the footer spanning rail + list (design spec §3).
/// Overlays — the project menu, Manage Projects and toasts — are drawn here, above every column.
struct RootView: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        RailView(state: state, session: session)
                            .frame(width: ShellMetrics.railWidth)
                        Group {
                            switch state.selectedSection {
                            case .messages: MessageListColumn(state: state, session: session)
                            case .files: FileListColumn(state: state, session: session)
                            case .agents: AgentListColumn(state: state)
                            case .settings: SettingsNavColumn(state: state)
                            case .board: BoardListColumn(state: state, session: session)
                            }
                        }
                        .frame(width: ShellMetrics.listWidth)
                    }
                    ProjectSwitcherTrigger(state: state, session: session)
                        .frame(height: ShellMetrics.footerHeight)
                }
                .frame(width: ShellMetrics.leftPaneWidth)
                switch state.selectedSection {
                case .messages: ConversationPane(state: state, session: session)
                case .files: FilePreviewPane(browser: state.files)
                case .agents: AgentDetailPane(state: state, session: session)
                case .settings: SettingsPane(state: state, session: session)
                case .board: BoardPane(state: state, session: session)
                }
            }

            if state.projectMenu != nil {
                // Any click outside the panel closes it (user 2026-09-03). Like a macOS menu, that
                // click only closes the panel.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.projectMenu = nil }
                    .accessibilityIdentifier("projectMenu.dismiss")
                ProjectMenuView(state: state, session: session)
                    .padding(.leading, ProjectMenuView.leading)
                    .padding(.bottom, ShellMetrics.footerHeight + ProjectMenuView.gapAboveFooter)
            }

            if state.isManagingProjects {
                ManageProjectsDialog(state: state, session: session)
            }

            if state.isCreatingAgent {
                CreateAgentDialog(state: state, session: session)
            }

            // After the creation dialog: its 配置 opens the provider dialog on top of it.
            if let target = state.providerEditor {
                ProviderEditor(state: state, target: target).id(target.id)
            }

            if let dialog = state.mcpDialog {
                MCPAddDialog(state: state, dialog: dialog).id(dialog.id)
            }

            if let target = state.hookEditor {
                HookEditorDialog(state: state, session: session, target: target).id(target.id)
            }

            if let id = state.conversationToClear, let conversation = state.conversations.conversation(id) {
                let count = conversation.messages.filter { !$0.isHidden }.count
                ConfirmDialog(kicker: "clear conversation", title: "清空这条对话？",
                              message: "「\(conversation.title)」的 \(count) 条消息和它的计划会全部删掉，找不回来。对话本身留在列表里。",
                              confirmTitle: "清空", identifier: "clearConversation",
                              onCancel: { state.conversationToClear = nil },
                              onConfirm: {
                                  state.conversationToClear = nil
                                  state.conversations.clearMessages(id)
                                  state.commandCards[id] = nil
                                  state.toasts.show("对话已清空", seconds: 2)
                              })
            }

            if let target = state.hookToDelete {
                ConfirmDialog(kicker: "delete hook", title: "删除这个 Hook？",
                              message: "「\(target.entry.handler.name)」会从 hooks.json 里删掉，之后不再运行。",
                              confirmTitle: "删除", identifier: "deleteHook",
                              onCancel: { state.hookToDelete = nil },
                              onConfirm: {
                                  state.hookToDelete = nil
                                  var file = state.hooks.file(target.scope)
                                  file.remove(target.entry)
                                  do {
                                      try state.hooks.save(file, to: target.scope)
                                      state.toasts.show("已删除 Hook")
                                  } catch {
                                      state.toasts.show("没有删除", note: error.localizedDescription, isError: true)
                                  }
                              })
            }

            if let id = state.skillToUninstall, let skill = state.skills.skill(id) {
                ConfirmDialog(kicker: "uninstall skill", title: "卸载「\(skill.name)」？",
                              message: skill.source == .builtIn
                                  ? "内置 Skill 卸载后不会自动装回，需要时可以重新导入它的文件夹。"
                                  : "卸载会删掉 Formora 里的这份副本，之后需要重新导入或重新生成。",
                              confirmTitle: "卸载", identifier: "uninstallSkill",
                              onCancel: { state.skillToUninstall = nil },
                              onConfirm: {
                                  state.skillToUninstall = nil
                                  do {
                                      try state.skills.uninstall(id)
                                      state.toasts.show("已卸载「\(skill.name)」")
                                  } catch {
                                      state.toasts.show("没有卸载", note: (error as? SkillProblem)?.message ?? error.localizedDescription,
                                                        isError: true)
                                  }
                              })
            }

            if let dialog = state.groupDialog {
                switch dialog {
                case .create: GroupCreateDialog(state: state, session: session)
                case .settings(let id): GroupSettingsDialog(state: state, session: session, conversationID: id).id(dialog.id)
                }
            }

            if let id = state.conversationToDelete, let conversation = state.conversations.conversation(id) {
                ConfirmDialog(kicker: "delete conversation", title: "删除「\(conversation.title)」？",
                              message: "这条会话的 \(conversation.messages.count) 条消息会一起删除，不能恢复。附件文件留在项目的「附件」文件夹里。",
                              confirmTitle: "删除", identifier: "deleteConversation",
                              onCancel: { state.conversationToDelete = nil },
                              onConfirm: {
                                  state.conversationToDelete = nil
                                  state.chat.discard(id)
                                  do {
                                      try state.conversations.delete(id)
                                      state.toasts.show("已删除「\(conversation.title)」")
                                  } catch {
                                      state.toasts.show("没有删除", note: (error as? ConversationProblem)?.message ?? error.localizedDescription,
                                                        isError: true)
                                  }
                              })
            }

            if let id = state.agentToDelete, let agent = state.agents.agent(id) {
                let count = state.conversations.count(ofAgent: id)
                ConfirmDialog(kicker: "delete agent", title: "删除「\(agent.displayName)」？",
                              message: "删除后这个 Agent 的名称、头像和模型配置会一起移除，不能恢复。"
                                  + (count > 0 ? "它参与的 \(count) 条会话会保留，显示为「已删除的 Agent」。" : ""),
                              confirmTitle: "删除", identifier: "deleteAgent",
                              onCancel: { state.agentToDelete = nil },
                              onConfirm: {
                                  state.agentToDelete = nil
                                  AgentActions.delete(id, state: state)
                              })
            }

            if let pending = state.pendingNavigation {
                ConfirmDialog(kicker: "unsaved changes", title: "有未保存的模型配置",
                              message: "「\(state.selectedAgent?.displayName ?? "")」的模型修改还没有保存。\(pending.consequence)前要放弃这些修改吗？",
                              cancelTitle: "继续编辑", confirmTitle: "放弃修改并离开", identifier: "unsavedDraft",
                              onCancel: { state.pendingNavigation = nil },
                              onConfirm: { state.discardDraftAndProceed() })
            }

            // The reasoning menu opens upward from its pill, above every column (spec §9.9); any click
            // outside closes it, like the project menu.
            if let id = state.reasoningMenuFor {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.reasoningMenuFor = nil }
                    .accessibilityIdentifier("reasoning.dismiss")
                ZStack(alignment: .topLeading) {
                    ReasoningMenu(state: state, conversationID: id)
                        .alignmentGuide(.top) { $0[.bottom] }
                        .offset(x: state.reasoningButtonFrame.minX, y: state.reasoningButtonFrame.minY - 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            ToastHost(center: state.toasts)
        }
        .frame(minWidth: ShellMetrics.minimumWindowSize.width, minHeight: ShellMetrics.minimumWindowSize.height)
        .background(Palette.ground.color)
        .ignoresSafeArea()
        .task(id: session.accessibleRoot?.path) { await openFiles() }
        .onChange(of: state.selectedSection) { _, section in
            if section == .files { Task { await state.files?.refresh() } }
            // Bob only lives in 设置: the panel closes with it (spec §8.8).
            if section != .settings { state.bobPanelOpen = false }
        }
        // Coming back to the window reads the reply that is on screen.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if state.selectedSection == .messages, let id = state.displayedConversationID { state.conversations.markRead(id) }
            state.skills.reload() // a Skill folder may have been added or changed in Finder meanwhile
            state.hooks.reload() // and hooks.json edited in another app
        }
    }

    /// One browser per reachable project folder; rebuilt when the project or its folder changes.
    private func openFiles() async {
        guard let root = session.accessibleRoot else {
            state.files = nil
            return
        }
        let browser = FileBrowser(rootURL: root)
        if let mode = VerificationHooks.htmlView(for: AppProfile.current) { browser.htmlView = mode }
        state.files = browser
        await browser.refresh()
        if let path = VerificationHooks.fileToSelect(for: AppProfile.current) {
            await browser.reveal(relativePath: path)
        }
    }
}
