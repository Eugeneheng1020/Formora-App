import SwiftUI

/// The far-left icon rail: account avatar, the four main sections, and 设置 pinned at the bottom.
struct RailView: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        // 未读角标 (设置 → 通知): the project's unread replies on 消息.
        let unread = state.notifications.badge ? state.conversations.unreadTotal(project: session.current?.id) : 0
        VStack(spacing: 0) {
            RailAvatarButton(image: state.account.avatar, initial: state.accountInitial) {
                state.guardNavigation("离开 Agent 配置") { state.openAccountSettings() }
            }
            Rectangle()
                .fill(Palette.railLine.color)
                .frame(width: 32, height: 1)
                .padding(.top, 14)
                .padding(.bottom, 12)
            VStack(spacing: 3) {
                ForEach(AppSection.mainNavigation) { section in
                    RailItemButton(section: section, isSelected: state.selectedSection == section,
                                   badge: section == .messages ? unread : 0) {
                        state.requestSection(section)
                    }
                }
            }
            Spacer(minLength: 0)
            RailItemButton(section: .settings, isSelected: state.selectedSection == .settings) {
                state.requestSection(.settings)
            }
            .padding(.bottom, 2)
        }
        .padding(.top, ShellMetrics.railTopPadding)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.railGround.color)
    }
}

/// The account avatar at the top of the rail. Clicking it opens 设置 → 账户 (design spec §5: anything
/// that looks clickable must do something).
struct RailAvatarButton: View {
    var image: NSImage?
    let initial: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccountAvatar(image: image, initial: initial, size: 36, style: .rail)
                .contentShape(AvatarShape())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账户设置")
        .accessibilityIdentifier("rail.avatar")
    }
}

struct RailItemButton: View {
    let section: AppSection
    let isSelected: Bool
    var badge = 0
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                IconView(section.icon, size: 20)
                    .shadow(color: isSelected ? Palette.accent.color : .clear, radius: 3)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            UnreadDot(count: badge)
                                .offset(x: 11, y: -8)
                                .accessibilityIdentifier("rail.\(section.rawValue).badge")
                        }
                    }
                Text(section.title)
                    .font(FormoraFont.ui(10, weight: 500))
                    .tracking(0.1)
            }
            .padding(.top, 8)
            .padding(.bottom, 7)
            .padding(.horizontal, 4)
            .frame(width: 64)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
            .overlay(alignment: .leading) {
                if isSelected {
                    UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                        .fill(Palette.accent.color)
                        .frame(width: 3, height: 20)
                        .offset(x: -1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("rail.\(section.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isSelected { return Palette.accent.color }
        return isHovering ? Palette.railInk.color : Palette.railInkDim.color
    }

    private var background: Color {
        if isSelected { return Palette.accentSoft.color }
        return isHovering ? Palette.railHover.color : .clear
    }
}
