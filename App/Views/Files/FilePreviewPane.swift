import AppKit
import SwiftUI

/// The 文件 detail column: header (`.file-preview-header`) and the preview, with a loading state that
/// lasts until the content has actually painted (todo #8).
struct FilePreviewPane: View {
    let browser: FileBrowser?
    /// The chat panel's switch (user 2026-09-22): in the header beside a file, at the top right when nothing is chosen.
    var isChatOpen = false
    var toggleChat: () -> Void = {}

    @State private var content: PreviewContent?
    @State private var isReady = false

    var body: some View {
        Group {
            if let browser, let node = browser.selectedNode {
                let isHTML = PreviewKind.forFile(named: node.name) == .html
                VStack(alignment: .leading, spacing: 0) {
                    header(node, path: browser.displayPath(of: node)) {
                        if isHTML {
                            SegmentedControl(options: [(HTMLViewMode.rendered, "预览"), (.source, "源码")],
                                             selection: Binding(get: { browser.htmlView }, set: { browser.htmlView = $0 }),
                                             identifier: "files.htmlView")
                        }
                        toggleButton
                    }
                    preview(for: node)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay { if !isReady { LoadingState() } }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 30)
                // Only HTML reloads when the 预览/源码 mode changes.
                .task(id: isHTML ? "\(node.id)#\(browser.htmlView.rawValue)" : node.id) {
                    await load(node, root: browser.root.url, htmlView: browser.htmlView)
                }
            } else {
                Text("从左侧文件树选择一个文件查看")
                    .font(FormoraFont.ui(13))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) { toggleButton.padding(.top, 28).padding(.trailing, 30) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.files")
    }

    private var toggleButton: some View {
        IconActionButton(icon: Icons.terminal, label: isChatOpen ? "关闭对话面板" : "打开对话面板", identifier: "files.chat.toggle",
                         action: toggleChat)
            .background(Circle().fill(isChatOpen ? Palette.surfaceRaised2.color : .clear))
    }

    private func header(_ node: FileNode, path: String, @ViewBuilder accessory: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                IconView(Icons.file, size: 20)
                    .foregroundStyle(Palette.accent.color)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.accentSoft.color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(FormoraFont.mono(15, weight: 700))
                        .foregroundStyle(Palette.ink.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("files.preview.name")
                    Text(path)
                        .font(FormoraFont.mono(11.5))
                        .foregroundStyle(Palette.inkFaint.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                accessory()
            }
            .padding(.bottom, 20)
            Rectangle().fill(Palette.line.color).frame(height: 1)
        }
        // As wide as the preview below, so the rule and the 预览/源码 switch follow the window (user 2026-09-11).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }

    @ViewBuilder private func preview(for node: FileNode) -> some View {
        switch content {
        case nil:
            Palette.surface.color
        case .document(let html):
            WebPreview(source: .html(html), token: node.id) { isReady = true }
                .background(Palette.surface.color)
        case .webPage(let url):
            WebPreview(source: .file(url), token: node.id) { isReady = true }
                .background(Palette.surface.color)
        case .structured(let root):
            ConfigTreeView(root: root).id(node.id)
        case .quickLook(let url):
            QuickLookPreview(url: url)
        case .info(let facts, let reason):
            FileInfoCard(facts: facts, reason: reason, url: node.url)
        }
    }

    private func load(_ node: FileNode, root: URL, htmlView: HTMLViewMode) async {
        isReady = false
        content = nil
        let url = node.url
        let result = await offMain { PreviewLoader.load(url, projectRoot: root, htmlView: htmlView) }
        guard !Task.isCancelled else { return }
        content = result
        switch result {
        case .document, .webPage: break // the web view reports when it has painted
        default: isReady = true
        }
    }
}

/// Spinner + 「正在加载…」, opaque so an unpainted web view never shows through.
private struct LoadingState: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在加载…").font(FormoraFont.ui(12)).foregroundStyle(Palette.inkFaint.color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.color)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("files.loading")
    }
}

/// What we can say about a file we will not render.
struct FileInfoCard: View {
    let facts: FileFacts
    let reason: PreviewContent.InfoReason
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(FormoraFont.ui(13.5, weight: 700)).foregroundStyle(Palette.ink.color)
                Text(detail).font(FormoraFont.ui(12)).foregroundStyle(Palette.inkMuted.color).lineSpacing(3)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                    row("类型", facts.typeDescription)
                    row("大小", ByteCountFormatter.string(fromByteCount: Int64(facts.byteCount), countStyle: .file))
                    if let modified = facts.modified {
                        row("修改时间", modified.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(.top, 4)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label { Text("在 Finder 中显示") } icon: { IconView(Icons.reveal, size: 14) }
                }
                .buttonStyle(FormoraButtonStyle())
                .padding(.top, 6)
                .accessibilityIdentifier("files.revealInFinder")
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.line.color, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.ground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.info")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
            Text(value).font(FormoraFont.mono(12)).foregroundStyle(Palette.ink.color).textSelection(.enabled)
        }
    }

    private var title: String {
        switch reason {
        case .empty: "这个文件是空的"
        case .tooLarge: "文件太大，不在这里预览"
        case .binary: "这类文件无法预览"
        case .unreadable: "无法读取这个文件"
        }
    }

    private var detail: String {
        switch reason {
        case .empty: "文件里还没有任何内容。"
        case .tooLarge(let limit): "超过 \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) 的文本文件不在这里打开，以免卡住界面。可以在 Finder 中用其他应用打开。"
        case .binary: "它不是文本文件，也不是系统预览支持的格式。可以在 Finder 中用对应的应用打开。"
        case .unreadable: "文件可能已被移动或删除，或者当前没有读取它的权限。"
        }
    }
}
