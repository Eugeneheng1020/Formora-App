import SwiftUI

/// 设置 → Bob (7h, B1): the model he answers with, and what to ask him. Talking to him is the floating panel at the
/// bottom-right of 设置 (spec §8.8; user 2026-09-12: 「设置 tab 只用于切换模型和列举示例」). Laid out like the other
/// settings pages (user 2026-09-13): the model on a standard setting row, each group of examples as full-width rows
/// under a heading the way 设置 → Hooks titles its groups.
struct BobSection: View {
    let state: AppState

    private var model: ModelReference? { state.bobModel.current(state.providers) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .bob, note: model == nil ? BobSession.noModel
                                    : "点设置页右下角的圆形按钮和 Bob 说话。这里选他用的模型，看看能问他什么") { EmptyView() }
            BobModelRow(state: state)
            ForEach(BobSession.examples) { group in
                Text(group.title)
                    .font(FormoraFont.ui(13, weight: 600))
                    .foregroundStyle(Palette.ink.color)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                VStack(spacing: 0) {
                    ForEach(group.items, id: \.self) { item in
                        BobExampleRow(text: item, isEnabled: model != nil) {
                            state.bobPanelOpen = true
                            state.bob.send(item)
                        }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            }
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
            : state.bobModel.chosen == nil ? "默认用第一个配好的模型，它不能用了会自动换下一个"
            : "Bob 回答问题、替你改设置都用这个模型"
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

/// One thing to ask, as a full-width row: the words, and 「问 Bob」, which opens his panel and asks it.
private struct BobExampleRow: View {
    let text: String
    let isEnabled: Bool
    let ask: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(FormoraFont.ui(12.5))
                .foregroundStyle(Palette.ink.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("问 Bob", action: ask)
                .buttonStyle(FormoraButtonStyle())
                .disabled(!isEnabled)
                .accessibilityIdentifier("bob.example")
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bob.exampleRow")
    }
}
