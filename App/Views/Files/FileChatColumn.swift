import AppKit
import SwiftUI

/// 文件's detail area with its fourth column (user 2026-09-22): the preview, a draggable divider, the chat panel. The
/// panel keeps 320…800 and leaves the preview 320; it slides in from the right.
struct FileChatColumn: View {
    let state: AppState
    let session: ProjectSession

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The panel's width when the drag began.
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let width = FileChat.clampWidth(state.filesChatWidth, detailWidth: proxy.size.width)
            HStack(spacing: 0) {
                FilePreviewPane(browser: state.files, isChatOpen: state.filesChatOpen) { state.toggleFilesChat() }
                if state.filesChatOpen {
                    divider(detailWidth: proxy.size.width)
                    FileChatPanel(state: state, session: session)
                        .frame(width: width)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.filesChatOpen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An 8-pt grab area over a 1-px line; the pointer says it resizes.
    private func divider(detailWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Palette.line.color)
            .frame(width: 1)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? state.filesChatWidth
                        dragStart = start
                        state.filesChatWidth = FileChat.clampWidth(start - value.translation.width, detailWidth: detailWidth)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("调整对话面板宽度")
            .accessibilityIdentifier("files.chat.divider")
    }
}
