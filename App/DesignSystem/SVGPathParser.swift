import SwiftUI

/// Parses SVG path data (`d` attribute) into a SwiftUI `Path`.
/// Supports every path command (M L H V C S Q T A Z, absolute and relative) and compact number syntax.
enum SVGPathParser {
    enum ParseError: Error, Equatable {
        case unexpectedCharacter(Int)
        case missingNumber(Int)
        case numbersAfterClose(Int)
    }

    static func parse(_ d: String) throws -> Path {
        var s = NumberScanner(Array(d.utf8))
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: UInt8?
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        while true {
            if let c = s.peekCommand() {
                command = c
                s.advance()
            } else if s.atEnd {
                break
            } else if !s.startsNumber {
                throw ParseError.unexpectedCharacter(s.index)
            } else if command == nil {
                throw ParseError.unexpectedCharacter(s.index)
            } else if command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                throw ParseError.numbersAfterClose(s.index)
            }
            guard let cmd = command else { break }
            let relative = cmd >= UInt8(ascii: "a")
            func point() throws -> CGPoint {
                let x = try s.number(), y = try s.number()
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            var cubicControl: CGPoint?
            var quadControl: CGPoint?

            switch cmd | 0x20 { // lowercase
            case UInt8(ascii: "m"):
                let p = try point()
                path.move(to: p)
                current = p
                subpathStart = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L") // implicit lineto
            case UInt8(ascii: "l"):
                current = try point()
                path.addLine(to: current)
            case UInt8(ascii: "h"):
                let x = try s.number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                let y = try s.number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                let c1 = try point(), c2 = try point(), p = try point()
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "s"):
                let c1 = lastCubicControl.map { reflect($0, about: current) } ?? current
                let c2 = try point(), p = try point()
                path.addCurve(to: p, control1: c1, control2: c2)
                cubicControl = c2
                current = p
            case UInt8(ascii: "q"):
                let c = try point(), p = try point()
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "t"):
                let c = lastQuadControl.map { reflect($0, about: current) } ?? current
                let p = try point()
                path.addQuadCurve(to: p, control: c)
                quadControl = c
                current = p
            case UInt8(ascii: "a"):
                let rx = try s.number(), ry = try s.number(), rotation = try s.number()
                let large = try s.flag(), sweep = try s.flag()
                let p = try point()
                appendArc(to: &path, from: current, to: p, rx: rx, ry: ry,
                          rotationDegrees: rotation, largeArc: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = subpathStart
            default:
                throw ParseError.unexpectedCharacter(s.index)
            }
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
        }
        if path.isEmpty { throw ParseError.missingNumber(0) }
        return path
    }

    private static func reflect(_ p: CGPoint, about c: CGPoint) -> CGPoint {
        CGPoint(x: 2 * c.x - p.x, y: 2 * c.y - p.y)
    }

    /// Endpoint → center parameterization (SVG 1.1 appendix F.6.5), split into ≤90° cubic segments.
    static func appendArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                          rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool) {
        guard p0 != p1 else { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let k = sqrt(lambda); rx *= k; ry *= k }

        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        var theta = theta1
        for index in 0..<segments {
            let next = theta + step
            let c1 = map(rx * (cos(theta) - t * sin(theta)), ry * (sin(theta) + t * cos(theta)))
            let c2 = map(rx * (cos(next) + t * sin(next)), ry * (sin(next) - t * cos(next)))
            let end = index == segments - 1 ? p1 : map(rx * cos(next), ry * sin(next))
            path.addCurve(to: end, control1: c1, control2: c2)
            theta = next
        }
    }
}

/// Byte scanner for SVG number syntax: `-.5.5` is two numbers, `1e-3` is one, commas and whitespace separate.
struct NumberScanner {
    private let bytes: [UInt8]
    private(set) var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { mutating get { skipSeparators(); return index >= bytes.count } }

    var startsNumber: Bool {
        mutating get {
            skipSeparators()
            guard index < bytes.count else { return false }
            let c = bytes[index]
            return isDigit(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
        }
    }

    mutating func advance() { index += 1 }

    mutating func peekCommand() -> UInt8? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        return Self.commands.contains(bytes[index]) ? bytes[index] : nil
    }

    mutating func number() throws -> CGFloat {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var sawDigit = false, sawDot = false
        while index < bytes.count {
            let c = bytes[index]
            if isDigit(c) {
                sawDigit = true
                index += 1
            } else if c == UInt8(ascii: "."), !sawDot {
                sawDot = true
                index += 1
            } else {
                break
            }
        }
        if sawDigit, index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            var probe = index + 1
            if probe < bytes.count, bytes[probe] == UInt8(ascii: "-") || bytes[probe] == UInt8(ascii: "+") { probe += 1 }
            if probe < bytes.count, isDigit(bytes[probe]) {
                index = probe
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
        }
        guard sawDigit, let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            throw SVGPathParser.ParseError.missingNumber(start)
        }
        return CGFloat(value)
    }

    /// Arc flags are a single `0` or `1` and may be written without separators (`a2 2 0 11 3 4`).
    mutating func flag() throws -> Bool {
        skipSeparators()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else {
            throw SVGPathParser.ParseError.missingNumber(index)
        }
        defer { index += 1 }
        return bytes[index] == UInt8(ascii: "1")
    }

    private mutating func skipSeparators() {
        while index < bytes.count, [9, 10, 13, 32, 44].contains(bytes[index]) { index += 1 }
    }

    private func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    private static let commands = Set("MmLlHhVvCcSsQqTtAaZz".utf8)
}
