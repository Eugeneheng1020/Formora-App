import CoreGraphics
import Foundation

/// A card's place on the canvas, with named fields so a conversation file reads plainly.
struct BoardPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// How a canvas is arranged (8a, K7). The state belongs to the canvas, not to each card: mixed cards would leave a new
/// card not knowing whom to follow. Auto keeps no positions; the first drag fixes the auto ones as the start.
struct BoardLayout: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case auto, custom }

    var mode: Mode = .auto
    var positions: [String: BoardPoint] = [:]
}

/// Where cards go and how they connect (K7).
enum BoardGeometry {
    static let cardWidth: Double = 300
    static let gap: Double = 32
    static let levelGap: Double = 36
    /// Before a card has been measured.
    static let defaultHeight: Double = 150

    /// The auto forest: roots side by side, children centred under their parent, each level below the measured
    /// height of the card above it. Roots never wrap (spec checklist 31).
    static func autoLayout(_ cards: [BoardCard], heights: [String: Double]) -> [String: BoardPoint] {
        let ids = Set(cards.map(\.id))
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for card in cards {
            if let parent = card.parentID, ids.contains(parent) {
                children[parent, default: []].append(card.id)
            } else {
                roots.append(card.id)
            }
        }
        var widths: [String: Double] = [:]
        func span(_ kids: [String]) -> Double { kids.map(width).reduce(0, +) + gap * Double(max(0, kids.count - 1)) }
        func width(_ id: String) -> Double {
            if let known = widths[id] { return known }
            let value = max(cardWidth, span(children[id] ?? []))
            widths[id] = value
            return value
        }
        var positions: [String: BoardPoint] = [:]
        func place(_ id: String, x: Double, y: Double) {
            let total = width(id)
            positions[id] = BoardPoint(x: x + (total - cardWidth) / 2, y: y)
            let kids = children[id] ?? []
            var cursor = x + (total - span(kids)) / 2
            let below = y + (heights[id] ?? defaultHeight) + levelGap
            for kid in kids {
                place(kid, x: cursor, y: below)
                cursor += width(kid) + gap
            }
        }
        var cursor = 0.0
        for root in roots {
            place(root, x: cursor, y: 0)
            cursor += width(root) + gap
        }
        return positions
    }

    /// Where every card is now: auto, or the user's positions — a card that came after the last drag goes under its
    /// parent, or to the right of everything.
    static func positions(_ cards: [BoardCard], layout: BoardLayout?, heights: [String: Double]) -> [String: BoardPoint] {
        let auto = autoLayout(cards, heights: heights)
        guard let layout, layout.mode == .custom else { return auto }
        var placed: [String: BoardPoint] = [:]
        for card in cards { if let point = layout.positions[card.id] { placed[card.id] = point } }
        for card in cards where placed[card.id] == nil {
            if let parent = card.parentID, let above = placed[parent] {
                placed[card.id] = BoardPoint(x: above.x, y: above.y + (heights[parent] ?? defaultHeight) + levelGap)
            } else {
                let right = placed.values.map { $0.x + cardWidth }.max() ?? 0
                placed[card.id] = BoardPoint(x: placed.isEmpty ? 0 : right + gap, y: 0)
            }
        }
        return placed
    }

    /// The right-angle line from a parent's bottom centre to a child's top centre — straight down when they line up:
    /// one drawing, two looks.
    static func connector(from parent: CGRect, to child: CGRect) -> [CGPoint] {
        let start = CGPoint(x: parent.midX, y: parent.maxY)
        let end = CGPoint(x: child.midX, y: child.minY)
        if abs(start.x - end.x) < 0.5 { return [start, end] }
        let middle = (start.y + end.y) / 2
        return [start, CGPoint(x: start.x, y: middle), CGPoint(x: end.x, y: middle), end]
    }

    /// The box around every card.
    static func bounds(_ positions: [String: BoardPoint], heights: [String: Double]) -> CGRect {
        guard !positions.isEmpty else { return .zero }
        let rects = positions.map { id, point in CGRect(x: point.x, y: point.y, width: cardWidth, height: heights[id] ?? defaultHeight) }
        return rects.dropFirst().reduce(rects[0]) { $0.union($1) }
    }
}
