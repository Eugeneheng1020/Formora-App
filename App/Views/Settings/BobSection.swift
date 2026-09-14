import SwiftUI

/// 设置 → Bob (7h, B1): the model he answers with, how far he goes without asking, whether he may operate the Mac, and
/// what to ask him. Talking to him is the floating panel at the bottom-right of 设置 (spec §8.8; user 2026-09-12:
/// 「设置 tab 只用于切换模型和列举示例」). Laid out like the other settings pages (user 2026-09-13): each setting on a
/// standard row; the examples as a stacked deck of cards (user 2026-09-14), one read at a time with his answer.
struct BobSection: View {
    let state: AppState

    private var model: ModelReference? { state.bobModel.current(state.providers) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .bob, note: model == nil ? BobSession.noModel
                                    : "Bob 用哪个模型、动手前问不问你；右下角的按钮就能和他说话。") { EmptyView() }
            BobModelRow(state: state)
            BobApprovalRow(state: state)
            BobComputerRow(state: state)
            Text("能问他什么")
                .font(FormoraFont.ui(13, weight: 600))
                .foregroundStyle(Palette.ink.color)
                .padding(.top, 18)
            Text("翻一翻，看 Bob 会怎么回答；「问 Bob」打开浮窗直接问他。")
                .font(FormoraFont.ui(11.5))
                .foregroundStyle(Palette.inkFaint.color)
                .padding(.top, 4)
            BobExampleDeck(state: state)
        }
        .task { await state.providers.loadAllConfigured() }
    }
}

/// The model Bob answers with (B2): the first configured one by default, or the one picked here.
private struct BobModelRow: View {
    let state: AppState

    var body: some View {
        let options = BobModel.options(state.providers)
        let current = state.bobModel.current(state.providers)
        // The page's note already says where to get one.
        let description = options.isEmpty && current == nil ? "还没有配好的模型"
            : state.bobModel.chosen == nil ? "默认用第一个配好的模型，不能用了自动换下一个"
            : "Bob 回答和改设置都用它"
        SettingRow(label: "模型", description: description) {
            if options.isEmpty, current == nil {
                Button("去「模型」配一个") { state.settingsCategory = .models }
                    .buttonStyle(FormoraButtonStyle())
                    .accessibilityIdentifier("bob.goModels")
            } else {
                Menu {
                    ForEach(options) { option in
                        Section(option.provider.name) {
                            ForEach(option.models) { model in
                                let reference = ModelReference(providerID: option.provider.id, modelID: model.id)
                                Button {
                                    state.bobModel.choose(reference)
                                } label: {
                                    if reference == current {
                                        Label(model.name ?? model.id, systemImage: "checkmark")
                                    } else {
                                        Text(model.name ?? model.id)
                                    }
                                }
                            }
                        }
                    }
                    if state.bobModel.chosen != nil {
                        Divider()
                        Button("改回默认：第一个配好的模型") { state.bobModel.choose(nil) }
                    }
                } label: {
                    Text(current.map { "\(state.providers.entry($0.providerID)?.name ?? $0.providerID) · \($0.modelID)" } ?? "选一个模型")
                        .font(FormoraFont.mono(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("bob.model")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.modelRow")
    }
}

/// 「权限模式」 (user 2026-09-13): the three an Agent has, 每次询问 until changed; what asks whatever the mode is written
/// under it (`BobSession.alwaysAsks`).
private struct BobApprovalRow: View {
    let state: AppState

    var body: some View {
        let mode = state.bobModel.approvalMode
        SettingRow(label: "权限模式", description: BobModel.note(mode) + BobModel.alwaysAsked) {
            SegmentedControl(options: ApprovalMode.allCases.map { ($0, $0.label) },
                             selection: Binding(get: { mode }, set: { set($0) }),
                             identifier: "bob.approvalMode")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.approvalRow")
    }

    private func set(_ mode: ApprovalMode) {
        guard mode != state.bobModel.approvalMode else { return }
        state.bobModel.setApprovalMode(mode)
        state.toasts.show("已保存", note: "Bob 的权限模式：\(mode.label)", seconds: 2)
    }
}

/// 「允许操作电脑」 (D97): off by default, like an Agent's (7j, B3). A build without it keeps the switch off and says why;
/// with it on and a permission missing, the row says which and offers 设置 → 电脑操作.
private struct BobComputerRow: View {
    let state: AppState

    var body: some View {
        let isOn = ComputerBuild.isAvailable && state.bobModel.allowsComputer
        let missing = isOn ? state.computer.missing : []
        let asking = state.bobModel.approvalMode == .yolo ? "「全部放行」下不问" : "每次回答第一次动手前先问"
        SettingRow(label: "允许操作电脑",
                   description: ComputerBuild.isAvailable
                       ? "看屏幕、点按打字、控制其他应用；\(asking)。"
                       : "App Store 版没有这个功能，官网版才有。") {
            HStack(spacing: 10) {
                if !missing.isEmpty {
                    Text("还缺：\(missing.map(\.title).joined(separator: "、"))")
                        .font(FormoraFont.ui(11.5))
                        .foregroundStyle(Palette.alert.color)
                    Button("去设置") { state.settingsCategory = .computer }
                        .buttonStyle(FormoraButtonStyle(kind: .ghost))
                        .accessibilityIdentifier("bob.computer.permissions")
                }
                FormoraSwitch(isOn: Binding(get: { isOn }, set: { set($0) }), label: "允许操作电脑", identifier: "bob.allowsComputer")
                    .disabled(!ComputerBuild.isAvailable)
            }
        }
        .task(id: isOn) { if isOn { await state.computer.refresh() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.computerRow")
    }

    private func set(_ on: Bool) {
        state.bobModel.setAllowsComputer(on)
        state.toasts.show("已保存", note: on ? "Bob 允许操作电脑：开" : "Bob 允许操作电脑：关", seconds: 2)
    }
}
