import SwiftUI

/// Footer trigger (`.project-switcher-btn`): chevron on the left, current project name, hover wash
/// running edge to edge across the whole 384pt footer (user 2026-09-03).
struct ProjectSwitcherTrigger: View {
    let state: AppState
    let session: ProjectSession

    @State private var isHovering = false

    private var name: String { session.current?.name ?? "" }

    var body: some View {
        Button {
            state.projectMenu = state.projectMenu == nil ? .list : nil
        } label: {
            HStack(spacing: 7) {
                IconView(Icons.chevronUpDown, size: 13)
                    .foregroundStyle(state.projectMenu != nil ? Palette.accent.color : Palette.railInkDim.color)
                Text(name)
                    .font(FormoraFont.mono(12, weight: 500))
                    .foregroundStyle(Palette.railInk.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isHovering ? Palette.railHover.color : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("切换项目，当前：\(name)")
        .accessibilityIdentifier("footer.projectSwitcher")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.railGround.color)
        .overlay(alignment: .top) { Rectangle().fill(Palette.railLine.color).frame(height: 1) }
    }
}

/// The switcher's panel (`.project-switcher-menu`), drawn by `RootView` above everything and anchored
/// 8pt above the footer. 364 wide with 10pt margins; rows run edge to edge.
struct ProjectMenuView: View {
    static let width: CGFloat = ShellMetrics.leftPaneWidth - 20
    static let leading: CGFloat = 10
    static let gapAboveFooter: CGFloat = 8

    let state: AppState
    let session: ProjectSession

    @State private var availability: [UUID: Bool] = [:]

    var body: some View {
        Group {
            if state.projectMenu == .newProject {
                VStack(alignment: .leading, spacing: 0) {
                    Text("新建项目")
                        .font(FormoraFont.ui(15, weight: 700))
                        .foregroundStyle(Palette.ink.color)
                        .padding(.bottom, 14)
                    NewProjectForm(layout: .menu, session: session,
                                   onCancel: { state.projectMenu = .list },
                                   onCreated: { _ in state.projectMenu = nil })
                }
                .padding(16)
            } else {
                list
            }
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surfaceRaised.color))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.lineStrong.color, lineWidth: 1))
        .softShadow()
        .background {
            // Esc closes the panel (spec §4.1: everything clickable is reachable from the keyboard).
            Button("") { state.projectMenu = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectMenu")
        .onAppear(perform: refreshAvailability)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(session.projects) { project in
                projectRow(project)
            }
            Rectangle().fill(Palette.line.color).frame(height: 1).padding(.vertical, 6)
            MenuActionRow(icon: Icons.plus, title: "新建项目", identifier: "projectMenu.new") {
                state.projectMenu = .newProject
            }
            // D98: the launch screen's 「打开已有项目」 here too — 新建项目 makes a new empty folder inside the one picked.
            MenuActionRow(icon: Icons.files, title: "打开已有项目", identifier: "projectMenu.openExisting") {
                state.projectMenu = nil
                state.guardNavigation("打开已有项目") { _ = session.openExistingFolder() }
            }
            MenuActionRow(icon: Icons.settings, title: "管理项目", identifier: "projectMenu.manage") {
                state.openManageProjects()
            }
        }
        .padding(.vertical, 6)
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        let isCurrent = project.id == session.current?.id
        let isAvailable = availability[project.id] ?? true
        return MenuRow(identifier: "projectMenu.row.\(project.name)") {
            state.projectMenu = nil
            if !isCurrent { state.guardNavigation("切换到项目 \(project.name)") { session.open(project) } }
        } content: { isHovering in
            HStack(spacing: 8) {
                Circle().frame(width: 5, height: 5).opacity(0.6)
                Text(project.name)
                    .font(FormoraFont.mono(12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if !isAvailable {
                    Text("不可用").font(FormoraFont.ui(10.5)).foregroundStyle(Palette.alert.color)
                }
            }
            .foregroundStyle(isCurrent ? Palette.accent.color : isHovering ? Palette.ink.color : Palette.inkMuted.color)
        }
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func refreshAvailability() {
        var result: [UUID: Bool] = [:]
        for project in session.projects {
            if case .unavailable = session.availability(of: project) { result[project.id] = false } else { result[project.id] = true }
        }
        availability = result
    }
}

private struct MenuActionRow: View {
    let icon: SVGIcon
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        MenuRow(identifier: identifier, action: action) { isHovering in
            HStack(spacing: 8) {
                IconView(icon, size: 14)
                Text(title).font(FormoraFont.ui(12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? Palette.ink.color : Palette.inkMuted.color)
        }
        .accessibilityLabel(title)
    }
}

/// A full-width hoverable row: square highlight so it can run edge to edge without the panel's
/// background showing at the corners.
private struct MenuRow<Content: View>: View {
    let identifier: String
    let action: () -> Void
    @ViewBuilder let content: (Bool) -> Content

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content(isHovering)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovering ? Palette.surfaceRaised2.color : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(identifier)
    }
}
