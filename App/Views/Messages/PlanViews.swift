import SwiftUI

/// The plan's steps (7d, D4; mockup `.todo-line`): open ones plain, the one in progress in accent, finished ones
/// ticked and faint, dropped ones struck through. Read-only — the list is the Agent's progress; the user adds with
/// `/todo` (deviation D43).
struct PlanList: View {
    let items: [PlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("还没有计划。用 /plan 开计划模式，Agent 会先出方案、列步骤；也可以用 /todo 要做的事 加一项。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { item in
                // The mark sits on the first line by top alignment, not a baseline guide: a `firstTextBaseline` guide on
                // a shape sent SwiftUI's layout into endless recursion once the text wrapped — the crash of 2026-09-14.
                HStack(alignment: .top, spacing: 9) {
                    mark(item.status).padding(.top, 2.5)
                    Text(item.text)
                        .font(FormoraFont.ui(12, weight: item.status == .active ? 600 : 400))
                        .foregroundStyle(item.status == .active ? Palette.accent.color
                                         : item.isOpen ? Palette.ink.color : Palette.inkFaint.color)
                        .strikethrough(item.status == .dropped)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.byUser {
                        Text("你加的").font(FormoraFont.ui(10.5)).foregroundStyle(Palette.inkFaint.color)
                    }
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("plan.item")
            }
        }
    }

    @ViewBuilder private func mark(_ status: PlanItem.Status) -> some View {
        switch status {
        case .pending:
            Circle().strokeBorder(Palette.inkFaint.color, lineWidth: 1.2).frame(width: 11, height: 11)
        case .active:
            Circle().fill(Palette.accent.color).frame(width: 11, height: 11)
        case .done:
            IconView(Icons.check, size: 12).foregroundStyle(Palette.success.color).frame(width: 11, height: 11)
        case .dropped:
            Rectangle().fill(Palette.inkFaint.color).frame(width: 9, height: 1.2).frame(width: 11, height: 11)
        }
    }
}

/// The plan docked above the composer while steps are open (spec §9.8b: what is pending stays in sight): one line
/// — 「计划 2/5 · 正在：…」 — that opens to the list. While the Agent isn't working, × closes the plan (user
/// 2026-09-17): the open steps are dropped and it no longer goes by them.
struct PlanStrip: View {
    let plan: [PlanItem]
    /// `nil` under a run: 停止 comes first.
    var close: (() -> Void)?

    @State private var isOpen = false

    var body: some View {
        let counted = plan.filter { $0.status != .dropped }
        let done = counted.filter { $0.status == .done }.count
        VStack(alignment: .leading, spacing: 0) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Text("计划").font(FormoraFont.ui(12, weight: 600)).foregroundStyle(Palette.ink.color)
                    Text("\(done)/\(counted.count)").font(FormoraFont.mono(11)).foregroundStyle(Palette.inkFaint.color)
                    if let active = plan.first(where: { $0.status == .active }) {
                        Text("正在：\(active.text)")
                            .font(FormoraFont.ui(12))
                            .foregroundStyle(Palette.inkMuted.color)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    IconView(Icons.chevronRight, size: 12)
                        .foregroundStyle(Palette.inkFaint.color)
                        .rotationEffect(.degrees(isOpen ? 90 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plan.strip.toggle")
            // Room for the × that lies over the row's end.
            .padding(.trailing, close == nil ? 0 : 28)
            if isOpen {
                PlanList(items: plan)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if let close {
                Button(action: close) {
                    IconView(Icons.close, size: 11).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.inkFaint.color)
                .help("关闭计划：剩下的步骤不再做")
                .accessibilityLabel("关闭计划")
                .accessibilityIdentifier("plan.strip.close")
                .padding(.top, 7.5)
                .padding(.trailing, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.strip")
    }
}

/// 计划模式 in the composer's tool row (D5; user 2026-09-23): `plan: on` in accent, `plan: off` grey — a click turns it
/// the other way. On, it stays on: every task is planned first.
struct PlanModePill: View {
    let isOn: Bool
    /// Where the tool row is narrow (user 2026-09-28): `plan` alone — on or off is its colour.
    var compact = false
    let toggle: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            Text(compact ? "plan" : isOn ? "plan: on" : "plan: off")
                .font(FormoraFont.mono(11))
                .foregroundStyle(isOn ? Palette.accent.color : isHovering && isEnabled ? Palette.ink.color : Palette.inkMuted.color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, compact ? 7 : 10)
                .frame(height: 26)
                .background(Capsule().fill(isOn ? Palette.accentSoft.color : isHovering && isEnabled ? Palette.surfaceRaised2.color : .clear))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Palette.line.color, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isOn ? "计划模式开着：每件事它先出方案、列好步骤，再接着做。点一下关闭" : "点一下开启计划模式：每件事先出方案再动手")
        .accessibilityLabel(isOn ? "计划模式：开" : "计划模式：关")
        .accessibilityIdentifier("composer.planMode")
    }
}
