import AppKit
import SwiftUI

/// 看板's detail column (8b): the selected conversation's canvas, or why there is none.
struct BoardPane: View {
    let state: AppState
    let session: ProjectSession

    var body: some View {
        let list = state.boardConversations(project: session.current?.id)
        Group {
            if let conversation = list.first(where: { $0.id == state.boardConversationID }) {
                BoardCanvas(state: state, session: session, conversation: conversation, cards: state.boardCards(conversation))
                    .id(conversation.id)
            } else {
                Text(list.isEmpty ? "这个项目下还没有对话" : "在左边选一个对话")
                    .font(FormoraFont.ui(13))
                    .foregroundStyle(Palette.inkFaint.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.board")
    }
}

/// The canvas's view onto the cards (K7–K8): zoom and pan, where the pointer is, and the wheel, pinch, middle-button
/// and space-drag input the canvas gets from an event monitor.
@MainActor
@Observable
final class BoardViewport {
    static let zoomRange: ClosedRange<CGFloat> = 0.4...1.6
    /// Where the first cards sit: under the title and the view controls.
    static let top: CGFloat = 148
    /// The canvas the event monitor reports to — one board on screen at a time.
    static weak var active: BoardViewport?

    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    /// The pointer over the canvas; `nil` when it is elsewhere, and then the wheel isn't the canvas's.
    var pointer: CGPoint?
    var size: CGSize = .zero
    /// The cards' box in canvas points, before zoom.
    var content: CGRect = .zero
    /// The user moved the view: no more recentring for them.
    var touched = false
    var spaceHeld = false
    /// A card is focused: 「运行过程」 over the right side (8c), the composer along the bottom (8d) — the wheel there
    /// scrolls them, not the canvas.
    var panelOpen = false

    func covered(_ point: CGPoint) -> Bool {
        guard panelOpen else { return false }
        if point.y >= size.height - BoardRunPanel.bottom + 8 { return true }
        let right = size.width - BoardRunPanel.edge
        return point.x >= right - BoardRunPanel.width && point.x <= right
            && point.y >= BoardRunPanel.top && point.y <= size.height - BoardRunPanel.bottom
    }

    /// The part of the canvas the cards can be seen in: left of 「运行过程」 while it is open.
    var visibleWidth: CGFloat {
        panelOpen ? max(240, size.width - BoardRunPanel.width - BoardRunPanel.edge) : size.width
    }

    /// Content centred across what can be seen, under the title (the mockup's 「单条链路居中比贴边更有呼吸感」).
    func centre() {
        pan = CGSize(width: max(24, (visibleWidth - content.width * zoom) / 2) - content.minX * zoom,
                     height: Self.top - content.minY * zoom)
    }

    /// The focused card out from under 「运行过程」 and the composer (8c): the least move that shows it, never under
    /// the title. Not the user's move — recentring stays on.
    func reveal(_ card: CGRect) {
        guard size != .zero else { return }
        let right = card.maxX * zoom + pan.width, limit = visibleWidth - 24
        if right > limit { pan.width -= right - limit }
        let left = card.minX * zoom + pan.width
        if left < 24 { pan.width += 24 - left }
        let bottom = card.maxY * zoom + pan.height, floor = size.height - (panelOpen ? BoardRunPanel.bottom : 24)
        if bottom > floor { pan.height -= min(bottom - floor, max(0, card.minY * zoom + pan.height - 110)) }
        clamp()
    }

    func reset() {
        zoom = 1
        touched = false
        centre()
    }

    func panBy(_ dx: CGFloat, _ dy: CGFloat) {
        pan.width += dx
        pan.height += dy
        touched = true
        clamp()
    }

    /// Around `anchor`: the point under the pointer stays under it.
    func zoom(by factor: CGFloat, at anchor: CGPoint) {
        let next = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        guard abs(next - zoom) > 0.0001 else { return }
        let ratio = next / zoom
        pan = CGSize(width: anchor.x - (anchor.x - pan.width) * ratio, height: anchor.y - (anchor.y - pan.height) * ratio)
        zoom = next
        touched = true
        clamp()
    }

    /// Bounded panning: at least 80 pt of the cards stays in view, so they can't be lost (K7).
    func clamp() {
        guard content != .zero, size != .zero else { return }
        let margin: CGFloat = 80
        let lowX = margin - content.maxX * zoom, highX = size.width - margin - content.minX * zoom
        let lowY = margin - content.maxY * zoom, highY = size.height - margin - content.minY * zoom
        pan.width = min(max(pan.width, min(lowX, highX)), max(lowX, highX))
        pan.height = min(max(pan.height, min(lowY, highY)), max(lowY, highY))
    }

    /// What the monitor saw, read off the event on the main thread before the event moves on.
    struct Input: Sendable {
        enum Kind: Sendable { case scroll, pinch, middleDrag, space(Bool), other }
        var kind: Kind
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var precise = false
        var command = false
        var magnification: CGFloat = 0
    }

    nonisolated static func input(_ event: NSEvent) -> Input {
        switch event.type {
        case .scrollWheel:
            return Input(kind: .scroll, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                         command: event.modifierFlags.contains(.command))
        case .magnify: return Input(kind: .pinch, magnification: event.magnification)
        case .otherMouseDragged: return Input(kind: .middleDrag, dx: event.deltaX, dy: event.deltaY)
        case .keyDown where event.keyCode == 49 && !event.isARepeat: return Input(kind: .space(true))
        case .keyDown where event.keyCode == 49: return Input(kind: .space(true))
        case .keyUp where event.keyCode == 49: return Input(kind: .space(false))
        default: return Input(kind: .other)
        }
    }

    /// `true`: the canvas took it. The wheel is the canvas's only while the pointer is over it; space only while nobody
    /// is typing.
    func handle(_ input: Input) -> Bool {
        switch input.kind {
        case .scroll:
            guard let pointer, !covered(pointer) else { return false }
            let scale: CGFloat = input.precise ? 1 : 8
            if input.command {
                zoom(by: exp(input.dy * scale / 240), at: pointer)
            } else {
                panBy(input.dx * scale, input.dy * scale)
            }
            return true
        case .pinch:
            guard let pointer, !covered(pointer) else { return false }
            zoom(by: 1 + input.magnification, at: pointer)
            return true
        case .middleDrag:
            guard let pointer, !covered(pointer) else { return false }
            panBy(input.dx, input.dy)
            return true
        case .space(let down):
            guard pointer != nil, !(NSApp.keyWindow?.firstResponder is NSText) else { return false }
            spaceHeld = down
            return true
        case .other:
            return false
        }
    }
}

/// One conversation's canvas (8b, K7–K10).
struct BoardCanvas: View {
    let state: AppState
    let session: ProjectSession
    let conversation: Conversation
    let cards: [BoardCard]

    @State private var viewport = BoardViewport()
    @State private var heights: [String: Double] = [:]
    @State private var dragging: Drag?
    @State private var panStart: CGSize?
    @State private var undoLayout: BoardLayout??
    @State private var keyboardCard: String?
    @State private var monitor: Any?
    /// The composer and whatever is docked above it (user 2026-09-15): the run panel stops short of them.
    @State private var composerHeight: CGFloat = 0
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Drag: Equatable {
        let id: String
        var offset: CGSize
    }

    private var positions: [String: BoardPoint] {
        var placed = BoardGeometry.positions(cards, layout: conversation.boardLayout, heights: heights)
        if let dragging, let point = placed[dragging.id] {
            placed[dragging.id] = BoardPoint(x: point.x + dragging.offset.width, y: point.y + dragging.offset.height)
        }
        return placed
    }

    private var roots: [BoardCard] { cards.filter { $0.parentID == nil } }

    /// Focus is selection (K11): one card, and its 「运行过程」 open.
    private var focusedCard: BoardCard? { cards.first { $0.id == state.boardFocus } }

    var body: some View {
        let placed = positions
        let bounds = BoardGeometry.bounds(placed, heights: heights)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                background
                stage(placed, size: proxy.size)
                    .scaleEffect(viewport.zoom, anchor: .topLeading)
                    .offset(viewport.pan)
                topBar
                if !cards.isEmpty { controls }
                if cards.isEmpty { empty }
                if let focused = focusedCard {
                    runPanel(focused)
                    composer(focused)
                }
            }
            .coordinateSpace(name: "board")
            .onChange(of: focusedCard?.id, initial: true) { _, id in
                let changed = (id != nil) != viewport.panelOpen
                viewport.panelOpen = id != nil
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    if changed, !viewport.touched { viewport.centre() }
                    revealFocused()
                }
            }
            .onContinuousHover(coordinateSpace: .named("board")) { phase in
                switch phase {
                case .active(let point): viewport.pointer = point
                case .ended: viewport.pointer = nil
                }
            }
            .onAppear {
                viewport.size = proxy.size
                viewport.content = bounds
                viewport.centre()
                revealFocused()
            }
            .onChange(of: proxy.size) { _, size in
                viewport.size = size
                if !viewport.touched { viewport.centre() }
                revealFocused()
            }
            // The cards measured or arranged: recentred, and the focused one still in view — unless the user has
            // moved the view (a card's drag counts).
            .onChange(of: bounds) { _, box in
                viewport.content = box
                guard !viewport.touched else { return }
                viewport.centre()
                revealFocused()
            }
        }
        .clipped()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            if focused, keyboardCard == nil { keyboardCard = state.boardFocus ?? roots.first?.id }
        }
        .onKeyPress(.leftArrow) { moveSibling(-1) }
        .onKeyPress(.rightArrow) { moveSibling(1) }
        .onKeyPress(.upArrow) { moveLevel(up: true) }
        .onKeyPress(.downArrow) { moveLevel(up: false) }
        .onKeyPress(.return) {
            guard let keyboardCard else { return .ignored }
            state.boardFocus = keyboardCard
            return .handled
        }
        .onKeyPress(.escape) {
            guard state.boardFocus != nil else { return .ignored }
            state.boardFocus = nil
            return .handled
        }
        .background {
            // ⌘0: back to 100 % and the content (K8).
            Button("") { viewport.reset() }.keyboardShortcut("0", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
        .onAppear(perform: startMonitor)
        .onDisappear(perform: stopMonitor)
    }

    // MARK: Layers

    /// The dot grid, and under the pointer the ripple (K9) — empty canvas: drag pans, double-click resets, a click
    /// lets go of the focused card.
    private var background: some View {
        ZStack(alignment: .topLeading) {
            DotGrid()
            if !reduceMotion, let pointer = viewport.pointer { Ripple(pointer: pointer) }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("board"))
                .onChanged { value in
                    if panStart == nil { panStart = viewport.pan }
                    guard let start = panStart else { return }
                    viewport.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                    viewport.touched = true
                }
                .onEnded { _ in
                    panStart = nil
                    viewport.clamp()
                }
        )
        .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.15)) { viewport.reset() } }
        .onTapGesture {
            state.boardFocus = nil
            keyboardCard = nil
        }
        .accessibilityHidden(true)
    }

    private func stage(_ placed: [String: BoardPoint], size: CGSize) -> some View {
        let visible = visibleCanvasRect(size)
        return ZStack(alignment: .topLeading) {
            Connectors(cards: cards, positions: placed, heights: heights)
            ForEach(cards.filter { isDrawn($0, placed: placed, in: visible) }) { card in
                let point = placed[card.id] ?? BoardPoint(x: 0, y: 0)
                BoardCardView(state: state, conversation: conversation, card: card, isFocused: state.boardFocus == card.id,
                              isKeyboard: isFocused && keyboardCard == card.id)
                    .frame(width: BoardGeometry.cardWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CardHeights.self, value: [card.id: proxy.size.height])
                    })
                    .offset(x: point.x, y: point.y)
                    .gesture(drag(card))
                    .onTapGesture { focus(card) }
                    .accessibilityAction { focus(card) }
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
        // Merged, not replaced: a card scrolled out of view keeps the height it was measured at.
        .onPreferenceChange(CardHeights.self) { measured in
            let merged = heights.merging(measured) { _, new in new }
            if merged != heights { heights = merged }
        }
    }

    /// The canvas on screen in canvas points, a card's width to spare (9a): only cards there are built — a board of 30
    /// side by side built all 30 on every opening.
    private func visibleCanvasRect(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .infinite }
        let zoom = max(viewport.zoom, 0.01)
        let margin = BoardGeometry.cardWidth
        return CGRect(x: -viewport.pan.width / zoom - margin, y: -viewport.pan.height / zoom - margin,
                      width: size.width / zoom + margin * 2, height: size.height / zoom + margin * 2)
    }

    /// The focused, the keyboard's and a dragged card are always built.
    private func isDrawn(_ card: BoardCard, placed: [String: BoardPoint], in visible: CGRect) -> Bool {
        if card.id == state.boardFocus || card.id == keyboardCard || card.id == dragging?.id { return true }
        guard let point = placed[card.id] else { return true }
        return visible.intersects(CGRect(x: point.x, y: point.y, width: BoardGeometry.cardWidth,
                                         height: heights[card.id] ?? BoardGeometry.defaultHeight))
    }

    /// `.canvas-topbar`: over the canvas, never in the way of it.
    private var topBar: some View {
        let done = cards.filter { $0.status.isDone }.count
        return VStack(alignment: .leading, spacing: 2) {
            Text("看板").font(FormoraFont.mono(10)).foregroundStyle(Palette.inkFaint.color).tracking(1)
            Text(BoardHeadline.of(conversation, agents: state.agents))
                .font(FormoraFont.ui(19, weight: 700))
                .tracking(-0.19)
                .foregroundStyle(Palette.ink.color)
                .lineLimit(1)
                .accessibilityIdentifier("board.title")
            Text("\(session.current?.name ?? "项目") · \(done)/\(cards.count) 个任务已完成")
                .font(FormoraFont.mono(11.5))
                .foregroundStyle(Palette.inkFaint.color)
        }
        .padding(.top, 20)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(stops: [.init(color: Palette.ground.color, location: 0.62), .init(color: Palette.ground.color.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    /// `.canvas-controls` (K7): bare icons under the title, on its 28 pt edge.
    private var controls: some View {
        HStack(spacing: 4) {
            IconActionButton(icon: Icons.recenter, label: "回到内容", identifier: "board.recenter") {
                withAnimation(.easeOut(duration: 0.15)) {
                    viewport.touched = false
                    viewport.centre()
                }
            }
            if conversation.boardLayout?.mode == .custom {
                IconActionButton(icon: Icons.relayout, label: "重新排列", identifier: "board.relayout") { relayout() }
            }
            if let undo = undoLayout {
                Button("撤销重新排列") {
                    state.conversations.setBoardLayout(undo, in: conversation.id)
                    undoLayout = nil
                }
                .buttonStyle(FormoraButtonStyle(kind: .ghost))
                .accessibilityIdentifier("board.undoRelayout")
            }
        }
        .padding(.leading, 28)
        .padding(.top, 104)
    }

    /// K11: over the canvas on the right, never a fourth column; it slides in from the edge. It ends above the composer
    /// and the decision docked over it, however tall (user 2026-09-15: the status line stayed in sight).
    private func runPanel(_ card: BoardCard) -> some View {
        BoardRunPanel(state: state, card: card, runIn: card.subtaskID ?? conversation.id)
            .padding(.top, BoardRunPanel.top)
            .padding(.bottom, max(BoardRunPanel.bottom, composerHeight + 22 + 14))
            .padding(.trailing, BoardRunPanel.edge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// K13: while a card is focused, the message composer itself — 28 pt from both sides, the canvas's edge line.
    private func composer(_ card: BoardCard) -> some View {
        ComposerView(state: state, session: session, conversation: conversation,
                     blockReason: ConversationReadiness.blockReason(of: conversation, agents: state.agents, currentProject: session.current,
                                                                   providers: state.providers),
                     boardCard: card)
            .background(GeometryReader { proxy in Color.clear.preference(key: ComposerHeight.self, value: proxy.size.height) })
            .onPreferenceChange(ComposerHeight.self) { composerHeight = $0 }
            .padding(.horizontal, BoardRunPanel.edge)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("这个对话还没有任务").font(FormoraFont.ui(13)).foregroundStyle(Palette.inkFaint.color)
            Button("去「消息」里说第一句话") { state.openConversation(conversation.id) }
                .buttonStyle(FormoraButtonStyle(kind: .primary))
                .accessibilityIdentifier("board.goMessages")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Acting

    private func revealFocused() {
        guard let id = focusedCard?.id, let point = positions[id] else { return }
        viewport.reveal(CGRect(x: point.x, y: point.y, width: BoardGeometry.cardWidth, height: heights[id] ?? BoardGeometry.defaultHeight))
    }

    /// The panel slides in when it opens; between cards it swaps at once (9a: animating the whole canvas on every change
    /// of focus redrew it frame by frame).
    private func focus(_ card: BoardCard) {
        let opening = state.boardFocus == nil
        withAnimation(opening && !reduceMotion ? .easeOut(duration: 0.18) : nil) { state.boardFocus = card.id }
        keyboardCard = card.id
    }

    /// A card moves after 4 pt (K8). The first move turns the whole canvas custom, with the auto positions as the start
    /// (K7) — a space held down pans instead.
    private func drag(_ card: BoardCard) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("board"))
            .onChanged { value in
                if viewport.spaceHeld {
                    if panStart == nil { panStart = viewport.pan }
                    if let start = panStart {
                        viewport.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                        viewport.touched = true
                    }
                    return
                }
                // Arranging is the user's move: the view stays where it is under the hand, now and after the drop.
                viewport.touched = true
                dragging = Drag(id: card.id, offset: CGSize(width: value.translation.width / viewport.zoom,
                                                            height: value.translation.height / viewport.zoom))
            }
            .onEnded { _ in
                panStart = nil
                guard let moved = dragging else { return }
                var layout = conversation.boardLayout ?? BoardLayout()
                if layout.mode == .auto {
                    layout = BoardLayout(mode: .custom, positions: BoardGeometry.positions(cards, layout: nil, heights: heights))
                }
                let base = layout.positions[moved.id] ?? BoardPoint(x: 0, y: 0)
                layout.positions[moved.id] = BoardPoint(x: base.x + moved.offset.width, y: base.y + moved.offset.height)
                state.conversations.setBoardLayout(layout, in: conversation.id)
                dragging = nil
                undoLayout = nil
            }
    }

    /// Back to the auto forest, with one undo (K7).
    private func relayout() {
        undoLayout = .some(conversation.boardLayout)
        state.conversations.setBoardLayout(nil, in: conversation.id)
        viewport.touched = false
    }

    /// ←/→ among the card's siblings (K10).
    private func moveSibling(_ step: Int) -> KeyPress.Result {
        guard let current = cards.first(where: { $0.id == keyboardCard }) else {
            keyboardCard = roots.first?.id
            return keyboardCard == nil ? .ignored : .handled
        }
        let siblings = cards.filter { $0.parentID == current.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == current.id }) else { return .ignored }
        keyboardCard = siblings[max(0, min(siblings.count - 1, index + step))].id
        return .handled
    }

    /// ↑ to the parent, ↓ to the first child (K10).
    private func moveLevel(up: Bool) -> KeyPress.Result {
        guard let current = cards.first(where: { $0.id == keyboardCard }) else { return .ignored }
        let next = up ? current.parentID : cards.first { $0.parentID == current.id }?.id
        guard let next else { return .ignored }
        keyboardCard = next
        return .handled
    }

    private func startMonitor() {
        BoardViewport.active = viewport
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .otherMouseDragged, .keyDown, .keyUp]) { event in
            let input = BoardViewport.input(event)
            let handled = MainActor.assumeIsolated { BoardViewport.active?.handle(input) ?? false }
            return handled ? nil : event
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if BoardViewport.active === viewport { BoardViewport.active = nil }
    }
}

/// Measured card heights, gathered for the forest (K7: measure before placing).
/// The canvas composer's height, decisions included.
private struct ComposerHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CardHeights: PreferenceKey {
    static let defaultValue: [String: Double] = [:]
    static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The 16 pt dot grid (K9): stays put while the cards pan and zoom above it.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 16
            var dots = Path()
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
                    x += step
                }
                y += step
            }
            context.fill(dots, with: .color(Palette.lineStrong.color))
        }
        .allowsHitTesting(false)
    }
}

/// The ripple (K9): within 132 pt of the pointer the dots brighten, fading out by 70 % of the way. It follows the
/// pointer and is still when the pointer is — a state, not an animation; only brighter, never coloured.
private struct Ripple: View {
    let pointer: CGPoint

    var body: some View {
        Canvas { context, _ in
            let step: CGFloat = 16
            let fade: CGFloat = 132 * 0.7
            let first = CGPoint(x: (floor((pointer.x - fade) / step) + 0.5) * step, y: (floor((pointer.y - fade) / step) + 0.5) * step)
            var y = first.y
            while y <= pointer.y + fade {
                var x = first.x
                while x <= pointer.x + fade {
                    let distance = hypot(x - pointer.x, y - pointer.y)
                    if distance < fade {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)),
                                     with: .color(Palette.inkFaint.color.opacity(Double(1 - distance / fade))))
                    }
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// The lines between cards (K7): parent's bottom to child's top, right-angled, an arrowhead at the child.
private struct Connectors: View {
    let cards: [BoardCard]
    let positions: [String: BoardPoint]
    let heights: [String: Double]

    var body: some View {
        let bounds = BoardGeometry.bounds(positions, heights: heights)
        let origin = CGPoint(x: min(0, bounds.minX) - 40, y: min(0, bounds.minY) - 40)
        Canvas { context, _ in
            context.translateBy(x: -origin.x, y: -origin.y)
            let style = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            for card in cards {
                guard let parent = card.parentID, let from = rect(parent), let to = rect(card.id) else { continue }
                let points = BoardGeometry.connector(from: from, to: to)
                var line = Path()
                line.addLines(points)
                context.stroke(line, with: .color(Palette.inkFaint.color), style: style)
                guard let end = points.last else { continue }
                var head = Path()
                head.addLines([CGPoint(x: end.x - 4.5, y: end.y - 6), end, CGPoint(x: end.x + 4.5, y: end.y - 6)])
                context.stroke(head, with: .color(Palette.inkFaint.color), style: style)
            }
        }
        .frame(width: max(1, bounds.maxX - origin.x + 40), height: max(1, bounds.maxY - origin.y + 40))
        .offset(x: origin.x, y: origin.y)
        .allowsHitTesting(false)
    }

    private func rect(_ id: String) -> CGRect? {
        guard let point = positions[id] else { return nil }
        return CGRect(x: point.x, y: point.y, width: BoardGeometry.cardWidth, height: heights[id] ?? BoardGeometry.defaultHeight)
    }
}
