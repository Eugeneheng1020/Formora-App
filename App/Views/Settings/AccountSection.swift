import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置 → 账户: avatar and nickname. The avatar is the rail's avatar (design spec §7.1).
struct AccountSection: View {
    let state: AppState

    private var account: AccountStore { state.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHead(category: .account, note: "名字和头像，只在本机显示。") { EmptyView() }
            SettingRow(label: "头像",
                       description: "PNG、JPEG 或 HEIC，不超过 10 MB；不设就显示昵称首字。") {
                HStack(spacing: 10) {
                    AccountAvatar(image: account.avatar, initial: account.initial, size: 56, style: .preview)
                        .accessibilityIdentifier("account.avatar")
                    CircleIconButton(icon: Icons.upload, label: "更换头像图片", identifier: "account.avatarUpload", action: pickAvatar)
                    if account.avatar != nil {
                        CircleIconButton(icon: Icons.trash, label: "移除头像", identifier: "account.avatarRemove", isDestructive: true) {
                            account.removeAvatar()
                        }
                    }
                }
            }
            SettingRow(label: "昵称", description: "显示在头像和消息气泡里。", showsRule: false) {
                NicknameField(account: account)
            }
        }
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.title = "选择头像图片"
        panel.prompt = "使用这张图片"
        panel.allowedContentTypes = AvatarImage.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try account.importAvatar(from: url)
        } catch {
            state.toasts.show("没有更换头像", note: (error as? AvatarImage.Problem)?.message ?? error.localizedDescription,
                              isError: true)
        }
    }
}

/// `.setting-input`: mono 12.5 pill, 220 wide. Saved as typed; the macOS full name shows when empty.
private struct NicknameField: View {
    let account: AccountStore

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: Binding(get: { account.nickname }, set: { account.setNickname($0) }))
            .textFieldStyle(.plain)
            .font(FormoraFont.mono(12.5))
            .foregroundStyle(Palette.ink.color)
            .focused($isFocused)
            .background(alignment: .leading) {
                if account.nickname.isEmpty {
                    Text(account.systemName).font(FormoraFont.mono(12.5)).foregroundStyle(Palette.inkFaint.color)
                        .allowsHitTesting(false)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .frame(width: 220)
            .background(Capsule().fill(Palette.surfaceRaised.color))
            .overlay(Capsule().strokeBorder(isFocused ? Palette.accent.color : Palette.lineStrong.color, lineWidth: 1))
            .accessibilityLabel("昵称")
            .accessibilityIdentifier("account.nickname")
    }
}

/// The account avatar: the image when set, otherwise the name's first letter; rounded square (D2).
struct AccountAvatar: View {
    enum Style { case rail, preview }

    let image: NSImage?
    let initial: String?
    let size: CGFloat
    let style: Style

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                AvatarShape().fill(style == .rail ? Palette.surfaceRaised2.color : Palette.accentSoft.color)
                Text(initial ?? "")
                    .font(FormoraFont.ui(style == .rail ? 13 : 20, weight: 700))
                    .foregroundStyle(style == .rail ? Palette.ink.color : Palette.accent.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(AvatarShape())
        .overlay {
            if style == .rail { AvatarShape().strokeBorder(Palette.lineStrong.color, lineWidth: 1) }
        }
    }
}

/// `.avatar-upload-btn`: a 34pt round icon button. The destructive variant is alert-coloured (rule R1).
struct CircleIconButton: View {
    let icon: SVGIcon
    let label: String
    let identifier: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 15)
                .foregroundStyle(foreground)
                .frame(width: 34, height: 34)
                .background(Circle().fill(background))
                .overlay(Circle().strokeBorder(isDestructive ? Palette.alertLine.color : Palette.lineStrong.color, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var foreground: Color {
        if isDestructive { return Palette.alert.color }
        return isHovering ? Palette.ink.color : Palette.inkMuted.color
    }

    /// Transparent until hovered (mockup `.avatar-upload-btn`).
    private var background: Color {
        guard isHovering else { return .clear }
        return isDestructive ? Palette.alertSoft.color : Palette.surfaceRaised2.color
    }
}
