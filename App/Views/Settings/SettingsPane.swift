import SwiftUI

/// 设置's detail column: one category at a time, scrolling inside (design spec §5); switching category
/// starts at the top. Content is at most 800 wide and left-aligned (spec §4.1).
struct SettingsPane: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        page
            // Bob floats over every category (7h, B1; spec §8.8): his button at the bottom-right, his panel above it.
            .overlay {
                GeometryReader { geometry in
                    BobFloat(state: state, session: session, panelHeight: min(540, geometry.size.height - 130))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
    }

    private var page: some View {
        ScrollView {
            Group {
                switch state.settingsCategory {
                case .account: AccountSection(state: state)
                case .models: ModelsSection(state: state)
                case .skills: SkillsSection(state: state)
                case .mcp: MCPSection(state: state)
                case .hooks: HooksSection(state: state, session: session)
                case .notifications: NotificationsSection(state: state)
                case .computer: ComputerSection(state: state)
                case .archive: ArchiveSection(state: state, session: session)
                case .usage: UsageSection(state: state)
                case .bob: BobSection(state: state)
                case .about: AboutSection(state: state)
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.vertical, 28)
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(state.settingsCategory)
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.settings")
    }
}

/// `.settings-section-head`: mono eyebrow, 15/700 title, 11pt faint note; the category's actions on the right.
struct SettingsSectionHead<Actions: View>: View {
    let category: SettingsCategory
    let note: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                Text(category.eyebrow)
                    .font(FormoraFont.mono(11))
                    .tracking(0.66)
                    .foregroundStyle(Palette.inkFaint.color)
                    .padding(.bottom, 6)
                Text(category.title)
                    .font(FormoraFont.ui(15, weight: 700))
                    .foregroundStyle(Palette.ink.color)
                    .padding(.top, 2)
                    .accessibilityIdentifier("settings.title")
                Text(note)
                    .font(FormoraFont.ui(11))
                    .foregroundStyle(Palette.inkFaint.color)
                    .lineSpacing(3)
                    // 5pt margin under a title whose web line box is ~2pt taller than SwiftUI's.
                    .padding(.top, 7)
                    .accessibilityIdentifier("settings.note")
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) { actions() }
        }
        .padding(.bottom, 16)
    }
}

/// `.setting-row`: description on the left, control on the right; 13pt vertical rhythm and a bottom rule.
struct SettingRow<Control: View>: View {
    let label: String
    let description: String
    var showsRule = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(FormoraFont.ui(13.5, weight: 600)).foregroundStyle(Palette.ink.color)
                Text(description)
                    .font(FormoraFont.ui(12))
                    .foregroundStyle(Palette.inkMuted.color)
                    .lineSpacing(2)
                    .frame(maxWidth: 340, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if showsRule { Rectangle().fill(Palette.line.color).frame(height: 1) }
        }
    }
}
