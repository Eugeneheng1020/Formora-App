import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Synthetic input carries this in `eventSourceUserData`, so the brake can tell it from the user's own (7j, C3).
enum ComputerInput {
    static let tag: Int64 = 0x464F524D  // "FORM"
    /// When Formora last posted input: the system's own echoes of it are not the user.
    @MainActor static var lastPosted = Date.distantPast
}

/// The Mac itself (7j, C1; the old app's phases 3–4): the window list, accessibility trees and actions, ScreenCaptureKit
/// screenshots, and input posted as events. Accessibility calls to other apps wait at most two seconds each.
@MainActor
final class MacDesktop: Desktop {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    private let source = CGEventSource(stateID: .hidSystemState)

    // MARK: Windows

    private func allWindows() -> [DesktopWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var frontTaken = false
        var bundles: [pid_t: String] = [:]
        return list.compactMap { info -> DesktopWindow? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 16, frame.height >= 16 else { return nil }
            var window = DesktopWindow(id: id, pid: pid, app: info[kCGWindowOwnerName as String] as? String ?? "",
                                       title: info[kCGWindowName as String] as? String ?? "", frame: frame)
            if bundles[pid] == nil { bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            window.bundleID = bundles[pid] ?? ""
            if !frontTaken, pid == front {
                window.isFront = true
                frontTaken = true
            }
            return window
        }
    }

    func windows() -> [DesktopWindow] { allWindows().filter { $0.pid != ownPID } }

    func window(at point: CGPoint) -> DesktopWindow? { allWindows().first { $0.frame.contains(point) } }

    // MARK: Accessibility

    /// `_AXUIElementGetWindow`, looked up once: an element's window id, to match it to the window list.
    private typealias GetWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowID: GetWindowID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowID.self)
    }()

    private func element(of window: DesktopWindow) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw DesktopProblem("没有辅助功能权限：去「设置 → 电脑操作」打开") }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 2)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value)
        guard status == .success, let elements = value as? [AXUIElement], !elements.isEmpty else {
            throw DesktopProblem(Self.message(status, fallback: "读不到「\(window.app)」的窗口"))
        }
        if let getWindowID = Self.getWindowID {
            for element in elements {
                var id: CGWindowID = 0
                if getWindowID(element, &id) == .success, id == window.id { return element }
            }
        }
        // Without the window id: the one at the same place and size.
        return elements.first { element in
            let frame = Self.frame(element)
            return abs(frame.minX - window.frame.minX) < 2 && abs(frame.minY - window.frame.minY) < 2
                && abs(frame.width - window.frame.width) < 2
        } ?? elements[0]
    }

    func tree(of window: DesktopWindow) throws -> AXNode {
        let root = try element(of: window)
        var budget = 3000
        return node(root, pid: window.pid, depth: 0, budget: &budget)
    }

    private static let attributes = ["AXRole", "AXTitle", "AXDescription", "AXValue", "AXEnabled", "AXFocused", "AXPosition", "AXSize",
                                     "AXChildren", "AXSubrole"] as CFArray

    private func node(_ element: AXUIElement, pid: pid_t, depth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, Self.attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        let values = (raw as? [AnyObject]) ?? []
        func value(_ index: Int) -> AnyObject? {
            guard index < values.count else { return nil }
            let item = values[index]
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
        var node = AXNode(role: value(0) as? String ?? "", handle: ElementHandle(element: element, pid: pid))
        node.title = value(1) as? String ?? ""
        node.subrole = value(9) as? String ?? ""
        node.detail = value(2) as? String ?? ""
        if let text = value(3) as? String {
            node.value = text
        } else if let number = value(3) as? NSNumber {
            node.value = number.stringValue
        }
        node.enabled = (value(4) as? Bool) ?? true
        node.focused = (value(5) as? Bool) ?? false
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let position = value(6), CFGetTypeID(position) == AXValueGetTypeID() { AXValueGetValue(position as! AXValue, .cgPoint, &origin) }
        if let extent = value(7), CFGetTypeID(extent) == AXValueGetTypeID() { AXValueGetValue(extent as! AXValue, .cgSize, &size) }
        node.frame = CGRect(origin: origin, size: size)
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success { node.actions = (names as? [String]) ?? [] }
        if depth < AXTreeText.depthLimit, budget > 0, let children = value(8) as? [AXUIElement] {
            for child in children where budget > 0 { node.children.append(self.node(child, pid: pid, depth: depth + 1, budget: &budget)) }
        }
        return node
    }

    private static func frame(_ element: AXUIElement) -> CGRect {
        var position: CFTypeRef?
        var extent: CFTypeRef?
        var origin = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &position) == .success, let position {
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        }
        if AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &extent) == .success, let extent {
            AXValueGetValue(extent as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }

    func element(at point: CGPoint) -> AXNode? {
        let system = AXUIElementCreateSystemWide()
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success, let found else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(found, &pid)
        var budget = 1
        return node(found, pid: pid, depth: AXTreeText.depthLimit, budget: &budget)
    }

    private func axElement(_ handle: ElementHandle) throws -> AXUIElement {
        guard let object = handle.element, CFGetTypeID(object) == AXUIElementGetTypeID() else { throw DesktopProblem("这个元素已经不在了") }
        return object as! AXUIElement
    }

    func press(_ handle: ElementHandle) throws {
        let status = AXUIElementPerformAction(try axElement(handle), "AXPress" as CFString)
        guard status == .success else { throw DesktopProblem(Self.message(status, fallback: "按不下去")) }
    }

    func setValue(_ value: String, of handle: ElementHandle) throws {
        let status = AXUIElementSetAttributeValue(try axElement(handle), "AXValue" as CFString, value as CFString)
        guard status == .success else { throw DesktopProblem(Self.message(status, fallback: "填不进去；试试 focus 后 type_text")) }
    }

    func focus(_ handle: ElementHandle) throws {
        let status = AXUIElementSetAttributeValue(try axElement(handle), "AXFocused" as CFString, kCFBooleanTrue)
        guard status == .success else { throw DesktopProblem(Self.message(status, fallback: "聚焦不了")) }
    }

    func perform(_ action: String, on handle: ElementHandle) throws {
        let status = AXUIElementPerformAction(try axElement(handle), action as CFString)
        guard status == .success else { throw DesktopProblem(Self.message(status, fallback: "做不了 \(action)")) }
    }

    func displays() -> [DesktopDisplay] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { DesktopDisplay(id: $0, frame: CGDisplayBounds($0), isMain: $0 == main) }
    }

    func focusedElement() -> AXNode? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), "AXFocusedUIElement" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var budget = 1
        return node(element, pid: pid, depth: AXTreeText.depthLimit, budget: &budget)
    }

    func raise(_ window: DesktopWindow) async throws {
        let element = try element(of: window)
        AXUIElementPerformAction(element, "AXRaise" as CFString)
        await activate(window.pid)
    }

    private static func message(_ status: AXError, fallback: String) -> String {
        switch status {
        case .apiDisabled: "没有辅助功能权限：去「设置 → 电脑操作」打开"
        case .cannotComplete: "那个应用没有回应（它可能正忙），过一会儿再试"
        case .invalidUIElement: "这个元素已经不在了：再读一次 tree"
        case .actionUnsupported: "这个元素不支持这个动作"
        case .attributeUnsupported: "这个元素没有这项"
        case .notImplemented: "那个应用不支持辅助功能"
        default: "\(fallback)（\(status.rawValue)）"
        }
    }

    // MARK: Screenshots

    func screenshot(_ window: DesktopWindow?, display: UInt32?, into folder: URL) async throws -> Shot {
        guard CGPreflightScreenCaptureAccess() else { throw DesktopProblem("没有屏幕录制权限：去「设置 → 电脑操作」打开") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(Int(Date.now.timeIntervalSince1970 * 1000)).png")
        return try await Self.capture(windowID: window?.id, frame: window?.frame, displayID: display, ownPID: ownPID, to: url)
    }

    /// Off the main actor: ScreenCaptureKit's objects stay inside, only the saved shot comes out. A full-screen
    /// shot leaves out Formora's own windows — the stop bar, the thread.
    nonisolated private static func capture(windowID: UInt32?, frame: CGRect?, displayID: UInt32?, ownPID: pid_t,
                                            to url: URL) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let area: CGRect
        if let windowID, let frame {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw DesktopProblem("截不到这个窗口：它可能被最小化或关掉了")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            area = frame
        } else {
            let wanted = displayID ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? (displayID == nil ? content.displays.first : nil) else {
                throw DesktopProblem(displayID == nil ? "找不到显示器" : "没有 \(wanted) 这块显示器：先用 displays 看有哪些")
            }
            let own = content.windows.filter { $0.owningApplication?.processID == ownPID }
            filter = SCContentFilter(display: display, excludingWindows: own)
            area = CGDisplayBounds(display.displayID)
        }
        let fit = min(1, min(1280 / area.width, 896 / area.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((area.width * fit).rounded()))
        configuration.height = max(1, Int((area.height * fit).rounded()))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DesktopProblem("截图存不下来")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DesktopProblem("截图存不下来") }
        return Shot(path: url.path, width: image.width, height: image.height, origin: area.origin,
                    scale: Double(area.width) / Double(image.width))
    }

    // MARK: Input

    private func activate(_ pid: pid_t) async {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { return }
        app.activate()
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func post(_ event: CGEvent?, pid: pid_t?, foreground: Bool) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: ComputerInput.tag)
        ComputerInput.lastPosted = .now
        if foreground || pid == nil {
            event.post(tap: .cghidEventTap)
        } else if let pid {
            event.postToPid(pid)
        }
    }

    func pointer(_ input: PointerInput, pid: pid_t?, foreground: Bool) async throws {
        if foreground, let pid { await activate(pid) }
        switch input {
        case .move(let point):
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left), pid: pid, foreground: foreground)
        case let .click(point, button, count, modifiers):
            let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .right
                ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: cgButton), pid: pid, foreground: foreground)
            for click in 1...count {
                for type in [down, up] {
                    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton)
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                    event?.flags = CGEventFlags(rawValue: modifiers)
                    post(event, pid: pid, foreground: foreground)
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        case .drag(let points):
            guard let first = points.first, let last = points.last else { return }
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: first, mouseButton: .left), pid: pid, foreground: foreground)
            for point in points.dropFirst() {
                try? await Task.sleep(for: .milliseconds(30))
                post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left), pid: pid, foreground: foreground)
            }
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: last, mouseButton: .left), pid: pid, foreground: foreground)
        case let .scroll(point, dx, dy):
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left), pid: pid, foreground: foreground)
            post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0),
                 pid: pid, foreground: foreground)
        }
    }

    func keys(_ chord: KeyChord, pid: pid_t?, foreground: Bool) async throws {
        if foreground, let pid { await activate(pid) }
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: chord.code, keyDown: isDown)
            event?.flags = CGEventFlags(rawValue: chord.modifiers)
            post(event, pid: pid, foreground: foreground)
        }
    }

    /// Text as Unicode, a few characters an event — any language, whatever the keyboard layout.
    func type(_ text: String, pid: pid_t?, foreground: Bool) async throws {
        if foreground, let pid { await activate(pid) }
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            index += 16
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                post(event, pid: pid, foreground: foreground)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Clipboard

    func readClipboard() -> String? { NSPasteboard.general.string(forType: .string) }

    func writeClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
