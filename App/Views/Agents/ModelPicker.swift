import SwiftUI

/// A text field styled as `.detail-input` (36, radius 8) or the dialog's `.text-input` (38, radius 9).
/// `onCommit` runs on Return and when focus leaves — how the auto-saved fields save.
struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var height: CGFloat = 36
    var isInvalid = false
    let identifier: String
    var onCommit: (() -> Void)?

    @FocusState private var isFocused: Bool

    private var radius: CGFloat { height > 36 ? 9 : 8 }
    private var font: Font { mono ? FormoraFont.mono(12) : FormoraFont.ui(height > 36 ? 12.5 : 12) }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Palette.ink.color)
            .focused($isFocused)
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(font).foregroundStyle(Palette.inkFaint.color).lineLimit(1).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, height > 36 ? 12 : 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isInvalid ? Palette.alert.color : isFocused ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .onSubmit { onCommit?() }
            .onChange(of: isFocused) { _, focused in if !focused { onCommit?() } }
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier(identifier)
    }
}

/// A menu that looks like `.detail-select` / `.select-input`.
struct DropdownMenu<Content: View>: View {
    let text: String
    var isPlaceholder = false
    var mono = false
    var height: CGFloat = 36
    let identifier: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu { content() } label: {
            HStack(spacing: 8) {
                Text(text)
                    .font(mono ? FormoraFont.mono(12) : FormoraFont.ui(12))
                    .foregroundStyle(isPlaceholder ? Palette.inkFaint.color : Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                IconView(Icons.chevronUpDown, size: 13).foregroundStyle(Palette.inkMuted.color)
            }
            .padding(.horizontal, height > 36 ? 12 : 11)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: height > 36 ? 9 : 8, style: .continuous).fill(Palette.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: height > 36 ? 9 : 8, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityIdentifier(identifier)
    }
}

/// Providers offered for an Agent's model: those with a key (user 2026-09-05), plus the current one if it lost
/// its key — kept and marked, never silently replaced (spec §8.7 rule 4). With no key anywhere, all of them,
/// so the dialog can lead to 配置 (A6).
@MainActor
enum ProviderChoices {
    static func options(_ providers: ProviderStore, current: String?) -> [ProviderEntry] {
        let configured = providers.entries.filter { providers.hasKey($0.id) }
        if configured.isEmpty { return providers.entries }
        if let current, !configured.contains(where: { $0.id == current }), let entry = providers.entry(current) {
            return configured + [entry]
        }
        return configured
    }
}

struct ProviderMenu: View {
    let providers: ProviderStore
    let selection: String?
    var height: CGFloat = 36
    let identifier: String
    let choose: (String) -> Void

    var body: some View {
        DropdownMenu(text: selection.flatMap { providers.entry($0) }.map(title) ?? "选择服务商", isPlaceholder: selection == nil,
                     height: height, identifier: identifier) {
            ForEach(ProviderChoices.options(providers, current: selection)) { entry in
                Button(title(entry)) { choose(entry.id) }
            }
        }
    }

    private func title(_ entry: ProviderEntry) -> String {
        "\(entry.name) · \(providers.hasKey(entry.id) ? "已配置" : "未配置")"
    }
}

/// 「全部模型 / 自定义 Model ID」.
struct ModelSourceControl: View {
    @Binding var source: AgentModelDraft.Source
    let identifier: String

    var body: some View {
        SegmentedControl(options: [(AgentModelDraft.Source.list, "全部模型"), (.custom, "自定义 Model ID")],
                         selection: $source, identifier: identifier)
            .fixedSize()
    }
}

/// The Model ID: a menu over the provider's real list (read on demand), or a text field for a custom ID.
struct ModelIDField: View {
    let providers: ProviderStore
    let providerID: String?
    let source: AgentModelDraft.Source
    @Binding var modelID: String
    var height: CGFloat = 36
    let identifier: String

    var body: some View {
        Group {
            if source == .custom || providerID == nil {
                InputField(placeholder: "provider/model-id", text: $modelID, mono: true, height: height, identifier: identifier)
            } else if let providerID {
                listField(providerID)
            }
        }
        .task(id: providerID) {
            if let providerID, providers.hasKey(providerID) { await providers.loadModels(providerID) }
        }
    }

    @ViewBuilder private func listField(_ providerID: String) -> some View {
        if !providers.hasKey(providerID) {
            note("服务商未配置，读不到模型列表", tone: Palette.alert.color)
        } else {
            switch providers.modelLists[providerID] {
            case .loaded(let models):
                DropdownMenu(text: modelID.isEmpty ? "选择模型" : modelID, isPlaceholder: modelID.isEmpty, mono: true,
                             height: height, identifier: identifier) {
                    ForEach(models) { model in Button(model.id) { modelID = model.id } }
                }
            case .unsupported:
                note("这家服务商不提供模型列表，请改用「自定义 Model ID」", tone: Palette.inkFaint.color)
            case .failed(let message):
                HStack(spacing: 10) {
                    note(message, tone: Palette.alert.color)
                    Button("重试") { Task { await providers.loadModels(providerID, refresh: true) } }
                        .buttonStyle(FormoraButtonStyle())
                }
            case .loading, nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取模型列表…").font(FormoraFont.ui(11.5)).foregroundStyle(Palette.inkFaint.color)
                }
                .frame(height: height)
            }
        }
    }

    private func note(_ text: String, tone: Color) -> some View {
        Text(text).font(FormoraFont.ui(11)).foregroundStyle(tone).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: height, alignment: .leading)
    }
}

/// `.model-meta-strip`: context window, max output, image input — real values or 「由 Provider 提供」.
struct ModelMetaStrip: View {
    let info: ModelInfo?

    var body: some View {
        HStack(spacing: 0) {
            cell("上下文窗口", info?.contextWindow.map(Self.tokens) ?? "由 Provider 提供")
            Rectangle().fill(Palette.line.color).frame(width: 1)
            cell("最大输出", info?.maxOutput.map(Self.tokens) ?? "由 Provider 提供")
            Rectangle().fill(Palette.line.color).frame(width: 1)
            cell("识图", info?.acceptsImages.map { $0 ? "支持" : "不支持" } ?? "未知")
            Rectangle().fill(Palette.line.color).frame(width: 1)
            // omp's catalog (user 2026-09-18): input / output per million tokens.
            cell("单价（每百万）", info?.cost.map(Self.price) ?? "未知")
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.modelMeta")
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(FormoraFont.ui(9.5)).foregroundStyle(Palette.inkFaint.color)
            Text(value).font(FormoraFont.mono(11)).foregroundStyle(Palette.inkMuted.color).lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「$3 / $15」: input and output per million tokens, as the catalog has them.
    static func price(_ cost: ModelCatalog.Cost) -> String { "$\(number(cost.input)) / $\(number(cost.output))" }

    static func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...3))) }

    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return "\(Int((Double(count) / 1_000_000).rounded()))M tokens" }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))K tokens" }
        return "\(count) tokens"
    }
}

/// `.connection-box`: 30pt icon disc + title and note; testing accent, success green, error alert.
struct ConnectionBox<Action: View>: View {
    enum Tone { case idle, testing, success, error }

    let tone: Tone
    let title: String
    let note: String?
    let action: Action

    init(tone: Tone, title: String, note: String?, @ViewBuilder action: () -> Action) {
        self.tone = tone
        self.title = title
        self.note = note
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 11) {
            Group {
                switch tone {
                case .testing: ProgressView().controlSize(.small)
                case .success: IconView(Icons.check, size: 15)
                case .error: IconView(Icons.alertCircle, size: 15)
                case .idle: IconView(Icons.plus, size: 15)
                }
            }
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(Circle().fill(disc))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                if let note {
                    Text(note).font(FormoraFont.ui(10.5)).foregroundStyle(Palette.inkMuted.color).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            action
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionBox")
    }

    private var color: Color {
        switch tone {
        case .idle: Palette.inkMuted.color
        case .testing: Palette.accent.color
        case .success: Palette.success.color
        case .error: Palette.alert.color
        }
    }

    private var disc: Color {
        switch tone {
        case .idle: Palette.surfaceRaised2.color
        case .testing: Palette.accentSoft.color
        case .success: Palette.successSoft.color
        case .error: Palette.alertSoft.color
        }
    }

    private var border: Color {
        switch tone {
        case .success: Palette.successLine.color
        case .error: Palette.alertLine.color
        default: Palette.line.color
        }
    }
}
