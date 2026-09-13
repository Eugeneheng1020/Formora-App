import AppKit
import SwiftUI

/// An Agent's avatar: the picture, or the role's first letter (not the Agent's name, spec §7.1). Rounded
/// square (D2). Stopped Agents are muted.
struct AgentAvatar: View {
    let image: NSImage?
    let initial: String
    let size: CGFloat
    var isMuted = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                    .opacity(isMuted ? 0.5 : 1)
            } else {
                AvatarShape().fill(isMuted ? Palette.surfaceRaised2.color : Palette.accentSoft.color)
                Text(initial)
                    .font(FormoraFont.ui(size * 0.35, weight: size >= 50 ? 700 : 600))
                    .foregroundStyle(isMuted ? Palette.inkFaint.color : Palette.accent.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(AvatarShape())
        .accessibilityHidden(true)
    }
}

/// `.list-add`: the 26pt round `+` in a list's title row.
struct ListAddButton: View {
    let label: String
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            IconView(Icons.plus, size: 14)
                .foregroundStyle(isHovering ? Palette.ink.color : Palette.inkMuted.color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isHovering ? Palette.surfaceRaised2.color : Palette.surfaceRaised.color))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// `.detail-block`: title 13.5/700 + faint note, actions on the right, 24pt below and a rule — except the last.
struct DetailBlock<Trailing: View, Content: View>: View {
    let title: String
    let note: String?
    let isLast: Bool
    let trailing: Trailing
    let content: Content

    init(title: String, note: String? = nil, isLast: Bool = false,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.isLast = isLast
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(FormoraFont.ui(13.5, weight: 700)).foregroundStyle(Palette.ink.color)
                    if let note {
                        Text(note).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) { trailing }
            }
            .padding(.bottom, 13)
            content
        }
        .padding(.bottom, isLast ? 0 : 24)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(Palette.line.color).frame(height: 1) }
        }
        .padding(.bottom, isLast ? 0 : 24)
    }
}

/// `.block-meta`: mono 10.5 faint — static facts and counts, never save state.
struct BlockMeta: View {
    let text: String
    var body: some View { Text(text).font(FormoraFont.mono(10.5)).foregroundStyle(Palette.inkFaint.color).lineLimit(1) }
}

/// `.save-state`: 「已保存」 faint, 「有未保存修改」 in ink — brightness, not alert colour (spec §4.1).
struct SaveState: View {
    let isDirty: Bool
    var body: some View {
        Text(isDirty ? "有未保存修改" : "已保存")
            .font(FormoraFont.mono(10.5))
            .foregroundStyle(isDirty ? Palette.ink.color : Palette.inkFaint.color)
            .accessibilityIdentifier("saveState")
    }
}

/// The 120pt label column of `.identity-form` / `.model-form`.
struct FormLabelCell: View {
    let text: String
    var body: some View {
        Text(text).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color).frame(width: 120, alignment: .leading)
    }
}

/// A project row with a check box (`.project-option` / `.project-permission-row`), the current project tagged.
struct ProjectCheckRow: View {
    let name: String
    let isOn: Bool
    let isCurrent: Bool
    let identifier: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 11) {
                CheckBox(isOn: isOn)
                Text(name).font(FormoraFont.mono(12)).foregroundStyle(isOn ? Palette.ink.color : Palette.inkMuted.color)
                    .lineLimit(1).truncationMode(.middle)
                if isCurrent {
                    Text("当前项目")
                        .font(FormoraFont.mono(10))
                        .foregroundStyle(Palette.accent.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Palette.accentSoft.color))
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// The system picker for avatar images (PNG, JPEG, HEIC).
@MainActor
func pickAvatarImage() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "选择头像图片"
    panel.prompt = "使用这张图片"
    panel.allowedContentTypes = AvatarImage.allowedTypes
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
}
