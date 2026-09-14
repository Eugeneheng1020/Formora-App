import SwiftUI

/// 设置 → 用量 (user 2026-09-14): what the replies cost — a period, the totals, a table by conversation, Agent or model,
/// the prices behind the numbers (editable), and a monthly budget.
struct UsageSection: View {
    let state: AppState

    @State private var period: UsageLedger.Period = .month
    @State private var grouping: UsageLedger.Grouping = .conversation
    @State private var budgetText = ""
    @State private var budgetCurrency: Currency = .cny

    private var prices: ModelPriceStore { state.prices }

    private var entries: [UsageLedger.Entry] {
        let all = UsageLedger.entries(state.conversations.conversations) { state.agents.agent($0)?.displayName ?? "已删除的 Agent" }
        return UsageLedger.filter(all, period: period)
    }

    private func price(_ model: ModelReference) -> ModelPrice? { prices.price(for: model)?.price }

    var body: some View {
        let entries = entries
        let totals = UsageLedger.totals(entries, price: price)
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .usage, note: "Agent 回复用掉的 token 和折算的花费；单价是参考值，可以改。") {
                SegmentedControl(options: UsageLedger.Period.allCases.map { ($0, $0.title) }, selection: $period, identifier: "usage.period")
            }
            totalsRow(totals)
            groupedTable(entries)
            priceTable(entries)
            budgetRow
        }
        .onAppear(perform: loadBudget)
    }

    // MARK: Totals

    private func totalsRow(_ totals: UsageLedger.Totals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                stat("回复", value: String(totals.runs), identifier: "usage.total.runs")
                stat("输入 token", value: UsageLedger.tokens(totals.input), identifier: "usage.total.input")
                stat("输出 token", value: UsageLedger.tokens(totals.output), identifier: "usage.total.output")
                stat("花费", value: UsageLedger.money(totals.cost), identifier: "usage.total.cost")
            }
            if !totals.unpricedModels.isEmpty {
                Text("还有 \(totals.unpricedModels.count) 个模型没有单价，它们的 token 算了、钱没算：\(totals.unpricedModels.map(\.modelID).joined(separator: "、"))")
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.alert.color)
                    .accessibilityIdentifier("usage.unpriced")
            }
        }
        .padding(.bottom, 18)
    }

    private func stat(_ label: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
            Text(value).font(FormoraFont.mono(15, weight: 600)).foregroundStyle(Palette.ink.color).lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surfaceRaised.color))
    }

    // MARK: Grouped table

    private func groupedTable(_ entries: [UsageLedger.Entry]) -> some View {
        let lines = UsageLedger.lines(entries, by: grouping, price: price)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("明细").font(FormoraFont.ui(13, weight: 600)).foregroundStyle(Palette.ink.color)
                Spacer()
                SegmentedControl(options: UsageLedger.Grouping.allCases.map { ($0, $0.title) }, selection: $grouping, identifier: "usage.grouping")
            }
            .padding(.bottom, 10)
            if lines.isEmpty {
                Text("这段时间没有回复。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("usage.empty")
            } else {
                tableHead(["名称", "回复", "输入", "输出", "花费"])
                ForEach(lines.prefix(40)) { line in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.name).font(FormoraFont.ui(12)).foregroundStyle(Palette.ink.color).lineLimit(1)
                            if !line.detail.isEmpty {
                                Text(line.detail).font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(String(line.runs), width: 50)
                        cell(UsageLedger.tokens(line.input), width: 90)
                        cell(UsageLedger.tokens(line.output), width: 90)
                        cell(UsageLedger.money(line.cost) + (line.unpriced ? " ?" : ""), width: 120)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("usage.line")
                }
                if lines.count > 40 {
                    Text("只列前 40 条。").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).padding(.top, 8)
                }
            }
        }
        .padding(.bottom, 24)
    }

    private func tableHead(_ titles: [String]) -> some View {
        HStack(spacing: 10) {
            Text(titles[0]).frame(maxWidth: .infinity, alignment: .leading)
            Text(titles[1]).frame(width: 50, alignment: .trailing)
            Text(titles[2]).frame(width: 90, alignment: .trailing)
            Text(titles[3]).frame(width: 90, alignment: .trailing)
            Text(titles[4]).frame(width: 120, alignment: .trailing)
        }
        .font(FormoraFont.ui(11))
        .foregroundStyle(Palette.inkFaint.color)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.lineStrong.color).frame(height: 1) }
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).font(FormoraFont.mono(11)).foregroundStyle(Palette.inkMuted.color).frame(width: width, alignment: .trailing).lineLimit(1)
    }

    // MARK: Prices

    private func priceTable(_ entries: [UsageLedger.Entry]) -> some View {
        let agentModels = state.agents.agents.compactMap { agent in agent.providerID.map { ModelReference(providerID: $0, modelID: agent.modelID) } }
        let models = UsageLedger.models(entries, agents: agentModels)
        return VStack(alignment: .leading, spacing: 0) {
            Text("单价（每百万 token）").font(FormoraFont.ui(13, weight: 600)).foregroundStyle(Palette.ink.color).padding(.bottom, 4)
            Text("改过的标「自定」，「恢复默认」回到参考值。")
                .font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).padding(.bottom, 10)
            ForEach(models, id: \.self) { model in
                PriceRow(model: model, prices: prices)
            }
            if models.isEmpty {
                Text("还没有模型。").font(FormoraFont.ui(12)).foregroundStyle(Palette.inkFaint.color).padding(.vertical, 8)
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: Budget

    private var budgetRow: some View {
        SettingRow(label: "每月预算", description: "本月花费超过时通知一次；留空不提醒。", showsRule: false) {
            HStack(spacing: 8) {
                SegmentedControl(options: Currency.allCases.map { ($0, $0.symbol) }, selection: Binding(get: { budgetCurrency }, set: { currency in
                    budgetCurrency = currency
                    saveBudget()
                }), identifier: "usage.budget.currency")
                FormoraTextField(placeholder: "金额", text: Binding(get: { budgetText }, set: { budgetText = $0; saveBudget() }),
                                 identifier: "usage.budget")
                    .frame(width: 90)
            }
        }
    }

    private func loadBudget() {
        if let budget = prices.budget {
            budgetText = budget.amount == budget.amount.rounded() ? String(Int(budget.amount)) : String(budget.amount)
            budgetCurrency = budget.currency
        }
    }

    private func saveBudget() {
        let trimmed = budgetText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if prices.budget != nil { prices.setBudget(nil) }
        } else if let amount = Double(trimmed), amount > 0 {
            prices.setBudget(UsageBudget(amount: amount, currency: budgetCurrency))
        }
    }
}

/// One model's prices: two numbers and a currency, editable in place.
private struct PriceRow: View {
    let model: ModelReference
    let prices: ModelPriceStore

    @State private var input = ""
    @State private var output = ""
    @State private var currency: Currency = .usd

    private var current: (price: ModelPrice, isDefault: Bool)? { prices.price(for: model) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.modelID).font(FormoraFont.ui(12)).foregroundStyle(Palette.ink.color).lineLimit(1)
                Text(model.providerID).font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            tag
            SegmentedControl(options: Currency.allCases.map { ($0, $0.symbol) }, selection: Binding(get: { currency }, set: { value in
                currency = value
                save()
            }), identifier: "usage.price.currency")
            field("输入", text: $input, identifier: "usage.price.input")
            field("输出", text: $output, identifier: "usage.price.output")
            Button("恢复默认") { prices.set(nil, for: model); load() }
                .buttonStyle(FormoraButtonStyle(kind: .ghost))
                .opacity(current?.isDefault == false ? 1 : 0)
                .disabled(current?.isDefault != false)
                .accessibilityIdentifier("usage.price.reset")
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage.price." + ModelPriceStore.key(model))
        .onAppear(perform: load)
    }

    @ViewBuilder private var tag: some View {
        let text = current == nil ? "没有单价" : current?.isDefault == true ? "默认" : "自定"
        Text(text)
            .font(FormoraFont.mono(10))
            .foregroundStyle(current == nil ? Palette.alert.color : Palette.inkFaint.color)
            .frame(width: 44, alignment: .trailing)
    }

    private func field(_ placeholder: String, text: Binding<String>, identifier: String) -> some View {
        FormoraTextField(placeholder: placeholder, text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = $0; save() }),
                         identifier: identifier)
            .frame(width: 64)
    }

    private func load() {
        guard let current else {
            input = ""
            output = ""
            return
        }
        input = Self.number(current.price.input)
        output = Self.number(current.price.output)
        currency = current.price.currency
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func save() {
        guard let inputValue = Double(input.trimmingCharacters(in: .whitespaces)),
              let outputValue = Double(output.trimmingCharacters(in: .whitespaces)), inputValue >= 0, outputValue >= 0 else { return }
        let price = ModelPrice(input: inputValue, output: outputValue, currency: currency)
        if price != current?.price || current == nil { prices.set(price, for: model) }
    }
}
