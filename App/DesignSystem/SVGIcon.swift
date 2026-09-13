import Foundation
import SwiftUI

/// The subset of SVG the design's line icons use: `path`, `rect`, `circle`, `ellipse`, `line`,
/// `polyline`, `polygon`, with `fill` / `stroke` / `stroke-width` inherited from the root `<svg>`.
/// Colors are always "currentColor" — the icon takes the view's foreground style.
struct SVGIcon: Sendable {
    struct Layer: Sendable {
        enum Paint: Sendable, Equatable {
            case stroke(width: CGFloat)
            case fill
        }

        let path: Path
        let paint: Paint
    }

    let viewBox: CGRect
    let layers: [Layer]

    var bounds: CGRect {
        layers.map { $0.path.boundingRect }.reduce(CGRect.null) { $0.union($1) }
    }

    init?(svg: String) {
        let collector = ElementCollector()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.delegate = collector
        guard parser.parse(), let root = collector.root else { return nil }

        let box = (root["viewBox"] ?? "0 0 24 24")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        guard box.count == 4 else { return nil }
        viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])

        var built: [Layer] = []
        for element in collector.elements {
            guard let path = Self.path(for: element) else { return nil }
            let fill = element.attributes["fill"] ?? root["fill"] ?? "currentColor"
            let stroke = element.attributes["stroke"] ?? root["stroke"] ?? "none"
            let width = Double(element.attributes["stroke-width"] ?? root["stroke-width"] ?? "1") ?? 1
            if fill != "none" { built.append(Layer(path: path, paint: .fill)) }
            if stroke != "none" { built.append(Layer(path: path, paint: .stroke(width: width))) }
        }
        layers = built
    }

    /// For icons compiled into the app: a parse failure is a programming error caught by `SVGIconTests`.
    init(validated svg: String, name: String) {
        guard let icon = SVGIcon(svg: svg) else { preconditionFailure("icon \(name) does not parse") }
        self = icon
    }

    private static func path(for element: ElementCollector.Element) -> Path? {
        let a = element.attributes
        func n(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "0") ?? 0) }
        switch element.name {
        case "path":
            return a["d"].flatMap { try? SVGPathParser.parse($0) }
        case "rect":
            let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
            let rx = a["rx"] != nil ? n("rx") : n("ry")
            let ry = a["ry"] != nil ? n("ry") : rx
            return rx > 0 ? Path(roundedRect: rect, cornerSize: CGSize(width: rx, height: ry)) : Path(rect)
        case "circle":
            let r = n("r")
            return Path(ellipseIn: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r))
        case "ellipse":
            return Path(ellipseIn: CGRect(x: n("cx") - n("rx"), y: n("cy") - n("ry"),
                                          width: 2 * n("rx"), height: 2 * n("ry")))
        case "line":
            var p = Path()
            p.move(to: CGPoint(x: n("x1"), y: n("y1")))
            p.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            return p
        case "polyline", "polygon":
            let values = (a["points"] ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            guard values.count >= 4, values.count.isMultiple(of: 2) else { return nil }
            var p = Path()
            p.move(to: CGPoint(x: values[0], y: values[1]))
            for i in stride(from: 2, to: values.count, by: 2) {
                p.addLine(to: CGPoint(x: values[i], y: values[i + 1]))
            }
            if element.name == "polygon" { p.closeSubpath() }
            return p
        default:
            return nil
        }
    }
}

private final class ElementCollector: NSObject, XMLParserDelegate {
    struct Element {
        let name: String
        let attributes: [String: String]
    }

    var root: [String: String]?
    var elements: [Element] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "svg" {
            root = attributes
        } else if !["g", "title", "desc"].contains(name) {
            // simple-icons files (provider logos) carry a <title>; it draws nothing.
            elements.append(Element(name: name, attributes: attributes))
        }
    }
}
