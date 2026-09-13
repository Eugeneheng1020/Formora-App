import SwiftUI

/// The plan's steps (7d, D4; mockup `.todo-line`): open ones plain, the one in progress in accent, finished ones
/// ticked and faint, dropped ones struck through. Read-only — the list is the Agent's progress; the user adds with
/// `/todo` (deviation D43).
struct PlanList: View {
    let items: [PlanItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("还没有计划。步骤多的任务，Agent 会先列出来；也可以用 /todo 要做的事 加一项。")
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkFaint.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    mark(item.status).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
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
/// — 「计划 2/5 · 正在：…」 — that opens to the list.
struct PlanStrip: View {
    let plan: [PlanItem]

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
            if isOpen {
                PlanList(items: plan)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.strip")
    }
}

/// 计划模式 in the composer's tool row (D5): on while it shows; × turns it off.
struct PlanModePill: View {
    let turnOff: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text("计划模式").font(FormoraFont.ui(11.5, weight: 600))
            Button(action: turnOff) {
                IconView(Icons.close, size: 10).frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭计划模式")
            .accessibilityLabel("关闭计划模式")
            .accessibilityIdentifier("composer.planMode.off")
        }
        .foregroundStyle(Palette.accent.color)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(Capsule().fill(Palette.accentSoft.color))
        .help("计划模式：它只看、只问、只出方案，不改文件、不运行命令")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.planMode")
    }
}

/// Under a plan-mode run that ended (D5): the way from the plan to the work.
struct PlanApprovalCard: View {
    let go: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("方案出来了").font(FormoraFont.ui(12.5, weight: 700)).foregroundStyle(Palette.ink.color)
                Spacer(minLength: 12)
                Text("PLAN").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color)
            }
            .padding(.bottom, 11)
            Text("计划模式下它没有改任何文件。觉得可以就点「按这个计划做」，计划模式随之关闭；要改哪里，直接在下面说。")
                .font(FormoraFont.ui(12))
                .foregroundStyle(Palette.inkMuted.color)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Button("按这个计划做", action: go)
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .padding(.top, 12)
                .accessibilityIdentifier("plan.execute")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.approval")
    }
}
