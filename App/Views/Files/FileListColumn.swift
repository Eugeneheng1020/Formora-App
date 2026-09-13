import SwiftUI

/// The 文件 list column: title, search, and the project folder as a tree (design `renderProjectTree`).
struct FileListColumn: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("文件")
                    .font(FormoraFont.ui(19, weight: 700))
                    .tracking(-0.19)
                    .foregroundStyle(Palette.ink.color)
                    .frame(height: 26, alignment: .leading)
                    .accessibilityIdentifier("list.title")
                    .padding(.bottom, 14)
                if let browser = state.files {
                    SearchField(placeholder: "搜索文件", text: Binding(get: { browser.searchText }, set: { browser.searchText = $0 }),
                                identifier: "files.search")
                        // `.search` margin 12 + the empty `.filter-tabs` row's 10pt bottom padding the mockup keeps here.
                        .padding(.bottom, 22)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 18)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.color)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.line.color).frame(width: 1) }
    }

    @ViewBuilder private var content: some View {
        if case .unavailable(let reason) = session.access {
            unavailable(reason)
        } else if let browser = state.files {
            FileTreeList(browser: browser)
                .task(id: browser.searchText) { await browser.performSearch() }
        } else {
            Spacer()
        }
    }

    private func unavailable(_ reason: ProjectFolders.UnavailableReason) -> some View {
        VStack(spacing: 10) {
            Text("项目文件夹不可用").font(FormoraFont.ui(13, weight: 600)).foregroundStyle(Palette.ink.color)
            Text(reason.message).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkFaint.color)
            Button("重新定位…") {
                guard let current = session.current else { return }
                if case .failed(let message) = session.relocate(current) {
                    state.toasts.show("没有更改路径", note: message, isError: true)
                }
            }
            .buttonStyle(FormoraButtonStyle())
            .accessibilityIdentifier("files.relocate")
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 34)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }
}

private struct FileTreeList: View {
    let browser: FileBrowser

    var body: some View {
        let rows = browser.visibleRows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    FileTreeRow(row: row,
                                isExpanded: browser.isExpanded(row.node),
                                isSelected: !row.node.isFolder && row.id == browser.selectedFileID,
                                isFocused: row.id == browser.focusedID) {
                        browser.select(row.node)
                    }
                }
                footer(rowCount: rows.count)
            }
            .padding(.top, 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { browser.moveFocus(by: -1); return .handled }
        .onKeyPress(.downArrow) { browser.moveFocus(by: 1); return .handled }
        .onKeyPress(.leftArrow) { browser.expandFocused(false); return .handled }
        .onKeyPress(.rightArrow) { browser.expandFocused(true); return .handled }
        .onKeyPress(.return) {
            if let id = browser.focusedID, let node = browser.node(withID: id) { browser.select(node) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.tree")
    }

    /// Design spec §4 / checklist 13: "nothing here" and "nothing matches" are different sentences.
    @ViewBuilder private func footer(rowCount: Int) -> some View {
        if browser.isSearching {
            if let outcome = browser.searchOutcome {
                if outcome.rows.isEmpty { emptyState("没有匹配的文件") }
                if outcome.truncated { emptyState("这个文件夹太大，只搜索了前 \(FileSearch.limit) 项") }
            }
        } else if browser.isEmptyProject {
            emptyState("这个项目文件夹还是空的")
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(FormoraFont.ui(12))
            .foregroundStyle(Palette.inkFaint.color)
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .padding(.vertical, 34)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("files.emptyState")
    }
}

/// `.tree-node`: 32 tall, radius 8, indent 12 + 18 per level; the whole row is the hit target (user 2026-09-03).
struct FileTreeRow: View {
    let row: TreeRow
    let isExpanded: Bool
    let isSelected: Bool
    let isFocused: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var node: FileNode { row.node }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if node.isFolder {
                    IconView(Icons.chevronRight, size: 13)
                        .foregroundStyle(Palette.inkFaint.color)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isExpanded)
                } else {
                    Color.clear.frame(width: 13, height: 13)
                }
                IconView(node.isFolder ? Icons.files : Icons.file, size: 15)
                    .foregroundStyle(node.isFolder ? Palette.accent.color.opacity(0.8) : Palette.inkFaint.color)
                Text(node.name)
                    .font(node.isFolder ? FormoraFont.ui(13, weight: 500) : FormoraFont.mono(12, weight: isSelected ? 600 : 400))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if node.isFolder, node.isEmptyFolder {
                    Text("空").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color).padding(.trailing, 10)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 18 + 12)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(node.isFolder ? "\(node.name) 文件夹" : node.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("files.row.\(node.name)")
    }

    private var labelColor: Color {
        if node.isFolder || isSelected || isHovering { return Palette.ink.color }
        return Palette.inkMuted.color
    }

    private var background: Color {
        if isSelected { return Palette.surfaceRaised2.color }
        return isHovering || isFocused ? Palette.surfaceRaised.color : .clear
    }
}
