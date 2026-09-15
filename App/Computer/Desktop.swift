import CoreGraphics
import Foundation

/// A window on screen (7j, C1), front to back as the window list gives them.
struct DesktopWindow: Equatable, Sendable {
    let id: UInt32
    let pid: pid_t
    let app: String
    let title: String
    /// Screen points, origin at the top left of the main display.
    let frame: CGRect
    var isFront = false
    /// `com.apple.TextEdit`: the name the window list gives is the localized one (「文本编辑」), so a model asking
    /// for TextEdit finds it by this.
    var bundleID = ""

    var label: String { title.isEmpty ? app : "\(app) — \(title)" }

    /// `app` and `title` as a selector or filter gives them: parts of the name or bundle id, and of the title.
    func matches(app query: String?, title part: String?) -> Bool {
        (query.map { app.localizedCaseInsensitiveContains($0) || bundleID.localizedCaseInsensitiveContains($0) } ?? true)
            && (part.map { title.localizedCaseInsensitiveContains($0) } ?? true)
    }
}

/// A display (7j-4): its id, where it sits in screen points, and whether it is the main one.
struct DesktopDisplay: Equatable, Sendable {
    let id: UInt32
    let frame: CGRect
    let isMain: Bool
}

/// What stands behind an element: the system's reference, or a test's stand-in.
final class ElementHandle: @unchecked Sendable {
    let element: AnyObject?
    let pid: pid_t

    init(element: AnyObject?, pid: pid_t) {
        self.element = element
        self.pid = pid
    }
}

/// An element of an accessibility tree, read once (C1).
struct AXNode: Sendable {
    var role: String
    /// `AXCloseButton`, `AXSearchField`…: all an unnamed button has to tell it from its neighbours.
    var subrole = ""
    var title = ""
    /// `AXDescription`: SwiftUI buttons often have only this.
    var detail = ""
    var value = ""
    var enabled = true
    var focused = false
    var frame: CGRect = .zero
    var actions: [String] = []
    var children: [AXNode] = []
    var handle: ElementHandle
}

/// A screenshot as saved (C1): where it is, how big, and how its pixels map back to the screen.
struct Shot: Equatable, Sendable {
    let path: String
    let width: Int
    let height: Int
    /// The top left of what was shot, in screen points, and points per pixel.
    let origin: CGPoint
    let scale: Double

    func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
}

enum MouseButton: String, Sendable {
    case left, right
}

/// Pointer input, in screen points.
enum PointerInput: Equatable, Sendable {
    case move(CGPoint)
    case click(CGPoint, button: MouseButton, count: Int, modifiers: UInt64)
    case drag([CGPoint])
    case scroll(CGPoint, dx: Int, dy: Int)
}

/// A key and its modifiers, from `cmd+shift+p`; US key codes.
struct KeyChord: Equatable, Sendable {
    let code: UInt16
    let modifiers: UInt64

    static let modifierFlags: [String: UInt64] = [
        "cmd": CGEventFlags.maskCommand.rawValue, "command": CGEventFlags.maskCommand.rawValue,
        "shift": CGEventFlags.maskShift.rawValue,
        "option": CGEventFlags.maskAlternate.rawValue, "opt": CGEventFlags.maskAlternate.rawValue,
        "alt": CGEventFlags.maskAlternate.rawValue,
        "ctrl": CGEventFlags.maskControl.rawValue, "control": CGEventFlags.maskControl.rawValue,
        "fn": CGEventFlags.maskSecondaryFn.rawValue,
    ]

    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111,
    ]

    /// `cmd+shift+p`, `return`, `esc`; `nil` when a part isn't a key this knows.
    static func parse(_ text: String) -> KeyChord? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let key = parts.last else { return nil }
        var modifiers: UInt64 = 0
        for part in parts.dropLast() {
            guard let flag = modifierFlags[part] else { return nil }
            modifiers |= flag
        }
        guard let code = codes[key] else { return nil }
        return KeyChord(code: code, modifiers: modifiers)
    }
}

struct DesktopProblem: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// What computer use needs of the Mac (7j, C1); tests hand in a stand-in.
@MainActor
protocol Desktop: AnyObject {
    /// Formora itself: never listed, never touched.
    var ownPID: pid_t { get }
    /// Other apps' windows, front to back.
    func windows() -> [DesktopWindow]
    /// The frontmost window under a point, Formora's included.
    func window(at point: CGPoint) -> DesktopWindow?
    func tree(of window: DesktopWindow) throws -> AXNode
    func element(at point: CGPoint) -> AXNode?
    func press(_ handle: ElementHandle) throws
    func setValue(_ value: String, of handle: ElementHandle) throws
    func focus(_ handle: ElementHandle) throws
    /// Any other of the element's actions, by its system name (`AXShowMenu`, `AXIncrement`…).
    func perform(_ action: String, on handle: ElementHandle) throws
    func raise(_ window: DesktopWindow) async throws
    func displays() -> [DesktopDisplay]
    /// The element that has the keyboard focus, in whichever app.
    func focusedElement() -> AXNode?
    /// A window, or a display (`nil`: the main one), at one pixel a point up to 1568 on the long edge, saved as PNG in
    /// `folder` (user 2026-09-15: readable).
    func screenshot(_ window: DesktopWindow?, display: UInt32?, into folder: URL) async throws -> Shot
    /// A tiny grey frame of the same target, for telling whether the screen is still changing (抽帧判稳).
    func frame(_ window: DesktopWindow?, display: UInt32?) async throws -> FrameSignature
    /// The element's value now, for an `expect` on it.
    func value(of handle: ElementHandle) throws -> String
    func pointer(_ input: PointerInput, pid: pid_t?, foreground: Bool) async throws
    func keys(_ chord: KeyChord, pid: pid_t?, foreground: Bool) async throws
    func type(_ text: String, pid: pid_t?, foreground: Bool) async throws
    func readClipboard() -> String?
    func writeClipboard(_ text: String)
}
