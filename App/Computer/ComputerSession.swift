import CoreGraphics
import Foundation

/// One conversation's computer use (7j, C1): the refs it handed out and the screenshots coordinates refer to, and
/// the running of a call's actions against a `Desktop`.
@MainActor
final class ComputerSession {
    private struct Entry {
        let handle: ElementHandle
        let window: UInt32
        let generation: Int
        let frame: CGRect
        let actions: [String]
    }

    /// Where `element_at` refs live: no window's tree renews them.
    private static let pointBucket: UInt32 = 0
    static let waitLimit: Double = 30

    private var entries: [String: Entry] = [:]
    private var generations: [UInt32: Int] = [:]
    private var counter = 0
    /// The latest screenshot of the screen (`"screen"`) and of each window (`"w<id>"`).
    private var shots: [String: Shot] = [:]

    // MARK: Refs

    /// A tree of `window` starts a new generation; refs of the one before stay valid, older ones don't (C1).
    private func beginTree(_ window: UInt32) -> Int {
        let next = (generations[window] ?? 0) + 1
        generations[window] = next
        // Refs older than the generation before are dead (see `entry`): their entries go with them, so a long run
        // that reads the same window a hundred times doesn't keep every node it ever saw (audit 2026-09-14).
        entries = entries.filter { $0.value.window != window || $0.value.generation >= next - 1 }
        return next
    }

    /// How many refs are held now (tests: bounded, whatever the run's length).
    var refCount: Int { entries.count }

    private func register(_ node: AXNode, window: UInt32, generation: Int) -> String {
        counter += 1
        let ref = "e\(counter)"
        entries[ref] = Entry(handle: node.handle, window: window, generation: generation, frame: node.frame, actions: node.actions)
        return ref
    }

    private func entry(_ ref: String) throws -> Entry {
        guard let entry = entries[ref] else {
            // A ref handed out earlier and pruned since (`beginTree`) is stale, not unknown.
            if ref.hasPrefix("e"), let number = Int(ref.dropFirst()), number > 0, number <= counter {
                throw DesktopProblem("\(ref) 过期了：这个窗口已经重新读过两次。再读一次 tree，用新的 ref")
            }
            throw DesktopProblem("没有 \(ref) 这个 ref：先用 tree 或 find 拿到 ref")
        }
        let current = generations[entry.window] ?? entry.generation
        guard entry.generation >= current - 1 else {
            throw DesktopProblem("\(ref) 过期了：这个窗口已经重新读过两次。再读一次 tree，用新的 ref")
        }
        return entry
    }

    // MARK: Running

    /// The actions in order; the first failure ends the batch and says which step and why.
    func run(_ actions: [ComputerAction], on desktop: Desktop, folder: URL, isCancelled: () -> Bool) async -> ToolResult {
        var lines: [String] = []
        var images: [String] = []
        for (index, action) in actions.enumerated() {
            if isCancelled() {
                lines.append("\(index + 1). 停下了：用户停止了，后面的步骤没有做。")
                return ToolResult(status: .stopped, output: lines.joined(separator: "\n"), images: images.isEmpty ? nil : images)
            }
            do {
                let (text, shot) = try await perform(action, on: desktop, folder: folder, isCancelled: isCancelled)
                lines.append("\(index + 1). \(action.kind.rawValue)：\(text)")
                if let shot { images.append(shot.path) }
            } catch let problem as DesktopProblem {
                lines.append("\(index + 1). \(action.kind.rawValue) 没有成功：\(problem.message)")
                if index + 1 < actions.count { lines.append("后面 \(actions.count - index - 1) 步没有做。") }
                return ToolResult(status: .failed, output: lines.joined(separator: "\n"), images: images.isEmpty ? nil : images)
            } catch {
                lines.append("\(index + 1). \(action.kind.rawValue) 没有成功：\(error.localizedDescription)")
                return ToolResult(status: .failed, output: lines.joined(separator: "\n"), images: images.isEmpty ? nil : images)
            }
        }
        return ToolResult(status: .done, output: lines.joined(separator: "\n"), images: images.isEmpty ? nil : images)
    }

    private func perform(_ action: ComputerAction, on desktop: Desktop, folder: URL,
                         isCancelled: () -> Bool) async throws -> (String, Shot?) {
        let foreground = action.string("delivery") != "background"
        switch action.kind {
        case .windows:
            let app = action.string("app")
            let list = desktop.windows().filter { $0.matches(app: app, title: action.string("title")) }
            guard !list.isEmpty else { return ("没有找到窗口" + (app.map { "（应用含「\($0)」）" } ?? ""), nil) }
            return ("\n" + list.prefix(40).map(Self.describe).joined(separator: "\n"), nil)

        case .screenshot:
            let window = try action.args["window"].map { try resolve($0, on: desktop) }
            let display = action.number("display").map { UInt32($0) }
            let shot = try await desktop.screenshot(window, display: display, into: folder)
            // A display's shot is the screen's latest, whichever display: its origin carries where that display sits.
            shots[window.map { "w\($0.id)" } ?? "screen"] = shot
            let target = window?.label ?? display.map { "显示器 \($0)" } ?? "整个屏幕"
            return ("\(target)，\(shot.width)×\(shot.height) 像素（1 像素 = \(Self.format(shot.scale)) 点）。坐标就按这张图的像素写", shot)

        case .tree:
            let window = try resolve(action.args["window"], on: desktop)
            let root = try desktop.tree(of: window)
            let depth = min(AXTreeText.depthLimit, max(1, Int(action.number("max_depth") ?? Double(AXTreeText.depthLimit))))
            let (found, truncated) = AXTreeText.lines(root, maxDepth: depth)
            let generation = beginTree(window.id)
            var text = ""
            for line in found {
                let row = String(repeating: "  ", count: line.depth) + "- " + AXTreeText.describe(line.node, ref: register(line.node, window: window.id, generation: generation))
                if text.count + row.count > AXTreeText.characterLimit {
                    text += "\n…（太长了，后面省略；用 find 按角色或标题找，或者 max_depth 小一些）"
                    return ("\(window.label)\n" + text, nil)
                }
                text += (text.isEmpty ? "" : "\n") + row
            }
            if truncated { text += "\n…（元素太多，只列了一部分；用 find 找具体的元素）" }
            return ("\(window.label)\n" + text, nil)

        case .find:
            let window = try resolve(action.args["window"], on: desktop)
            let root = try desktop.tree(of: window)
            let role = action.string("role")?.lowercased()
            let title = action.string("title")?.lowercased()
            let value = action.string("value")?.lowercased()
            guard role != nil || title != nil || value != nil else { throw DesktopProblem("find 至少要给 role、title、value 之一") }
            let generation = beginTree(window.id)
            let matches = AXTreeText.lines(root, maxDepth: AXTreeText.depthLimit).lines.map(\.node).filter { node in
                (role.map { AXTreeText.role(node.role).contains($0) } ?? true)
                    && (title.map { (node.title + " " + node.detail).lowercased().contains($0) } ?? true)
                    && (value.map { node.value.lowercased().contains($0) } ?? true)
            }
            guard !matches.isEmpty else { return ("在\(window.label)里没有找到", nil) }
            let rows = matches.prefix(30).map { "- " + AXTreeText.describe($0, ref: register($0, window: window.id, generation: generation)) }
            return ("\n" + rows.joined(separator: "\n"), nil)

        case .elementAt:
            let point = try self.point(action, on: desktop)
            guard let node = desktop.element(at: point) else { return ("这个位置没有读得到的元素", nil) }
            let generation = generations[Self.pointBucket] ?? 0
            return (AXTreeText.describe(node, ref: register(node, window: Self.pointBucket, generation: generation)), nil)

        case .readClipboard:
            return ("「\(desktop.readClipboard() ?? "")」", nil)

        case .displays:
            let rows = desktop.displays().map { display in
                "- [display=\(display.id)] \(Int(display.frame.width))×\(Int(display.frame.height)) at (\(Int(display.frame.minX)),\(Int(display.frame.minY)))\(display.isMain ? "（主显示器）" : "")"
            }
            return (rows.isEmpty ? "读不到显示器" : "\n" + rows.joined(separator: "\n"), nil)

        case .focused:
            guard let node = desktop.focusedElement() else { return ("没有读得到的焦点元素", nil) }
            if node.handle.pid == desktop.ownPID { return ("焦点在 Formora 自己的窗口里", nil) }
            let generation = generations[Self.pointBucket] ?? 0
            return (AXTreeText.describe(node, ref: register(node, window: Self.pointBucket, generation: generation)), nil)

        case .perform:
            guard let ref = action.string("ref"), let name = action.string("name") else {
                throw DesktopProblem("perform 要给 ref 和 name：name 照那个元素 actions: 里写的（比如 showmenu、increment）")
            }
            let entry = try entry(ref)
            try guardOwn(entry.handle.pid, desktop)
            let wanted = AXTreeText.action(name)
            guard let raw = entry.actions.first(where: { AXTreeText.action($0) == wanted }) else {
                let offered = entry.actions.map(AXTreeText.action).joined(separator: "、")
                throw DesktopProblem("\(ref) 没有 \(name) 这个动作；它有：\(offered.isEmpty ? "没有" : offered)")
            }
            try desktop.perform(raw, on: entry.handle)
            return ("对 \(ref) 执行了 \(wanted)", nil)

        case .wait:
            let limit = min(Self.waitLimit, max(0, action.number("seconds") ?? 5))
            let deadline = Date.now.addingTimeInterval(limit)
            let role = action.string("role")?.lowercased()
            let title = action.string("title")?.lowercased()
            let value = action.string("value")?.lowercased()
            let waitsForElement = action.args["window"] != nil && (role != nil || title != nil || value != nil)
            let waitsForWindow = !waitsForElement && (action.string("app") != nil || title != nil)
            repeat {
                if isCancelled() { throw DesktopProblem("用户停止了") }
                if waitsForElement, let window = try? resolve(action.args["window"], on: desktop), let root = try? desktop.tree(of: window) {
                    let hit = AXTreeText.lines(root).lines.contains { line in
                        (role.map { AXTreeText.role(line.node.role).contains($0) } ?? true)
                            && (title.map { (line.node.title + " " + line.node.detail).lowercased().contains($0) } ?? true)
                            && (value.map { line.node.value.lowercased().contains($0) } ?? true)
                    }
                    if hit { return ("出现了", nil) }
                } else if waitsForWindow {
                    if desktop.windows().contains(where: { $0.matches(app: action.string("app"), title: title) }) { return ("窗口出现了", nil) }
                }
                try? await Task.sleep(for: .milliseconds(250))
            } while Date.now < deadline
            return (waitsForElement || waitsForWindow ? "等了 \(Self.format(limit)) 秒，没有出现" : "等了 \(Self.format(limit)) 秒", nil)

        case .click:
            let (point, pid) = try target(action, on: desktop)
            let button = MouseButton(rawValue: action.string("button") ?? "left") ?? .left
            let count = max(1, min(3, Int(action.number("count") ?? 1)))
            var modifiers: UInt64 = 0
            for name in (action.args["modifiers"] as? [String]) ?? [] {
                guard let flag = KeyChord.modifierFlags[name.lowercased()] else { throw DesktopProblem("不认识的修饰键「\(name)」") }
                modifiers |= flag
            }
            try await desktop.pointer(.click(point, button: button, count: count, modifiers: modifiers), pid: pid, foreground: foreground)
            return ("在 (\(Int(point.x)), \(Int(point.y))) \(count >= 2 ? "双击" : "点击")了", nil)

        case .move:
            let (point, pid) = try target(action, on: desktop)
            try await desktop.pointer(.move(point), pid: pid, foreground: foreground)
            return ("鼠标移到了 (\(Int(point.x)), \(Int(point.y)))", nil)

        case .drag:
            guard let raw = action.args["path"] as? [[Any]], raw.count >= 2 else { throw DesktopProblem("drag 要给 path：至少两个点 [[x,y],[x,y]]") }
            let shot = try latestShot(for: action.args["window"], on: desktop)
            let points = try raw.map { pair -> CGPoint in
                guard pair.count == 2, let x = (pair[0] as? NSNumber)?.doubleValue, let y = (pair[1] as? NSNumber)?.doubleValue else {
                    throw DesktopProblem("path 里每个点写成 [x, y]")
                }
                return shot.point(x, y)
            }
            let pid = try pidUnder(points[0], on: desktop)
            try await desktop.pointer(.drag(points), pid: pid, foreground: foreground)
            return ("拖过了 \(points.count) 个点", nil)

        case .scroll:
            let (point, pid) = try target(action, on: desktop)
            let dx = Int(action.number("dx") ?? 0)
            let dy = Int(action.number("dy") ?? 0)
            guard dx != 0 || dy != 0 else { throw DesktopProblem("scroll 要给 dx 或 dy") }
            try await desktop.pointer(.scroll(point, dx: dx, dy: dy), pid: pid, foreground: foreground)
            return ("滚动了（dx \(dx)，dy \(dy)）", nil)

        case .typeText:
            guard let text = action.args["text"] as? String, !text.isEmpty else { throw DesktopProblem("type_text 要给 text") }
            var pid: pid_t?
            if let ref = action.string("ref") {
                let entry = try entry(ref)
                try guardOwn(entry.handle.pid, desktop)
                try desktop.focus(entry.handle)
                pid = entry.handle.pid
            } else if let selector = action.args["window"] {
                pid = try resolve(selector, on: desktop).pid
            }
            try await desktop.type(text, pid: pid, foreground: foreground)
            return ("输入了 \(text.count) 个字", nil)

        case .keys:
            guard let text = action.string("keys") else { throw DesktopProblem("keys 要给按键，比如 cmd+s、return") }
            guard let chord = KeyChord.parse(text) else { throw DesktopProblem("「\(text)」不是认得的按键写法，比如 cmd+shift+p、return、esc、up") }
            let pid = try action.args["window"].map { try resolve($0, on: desktop).pid }
            try await desktop.keys(chord, pid: pid, foreground: foreground)
            return ("按了 \(text)", nil)

        case .press, .setValue, .focus:
            guard let ref = action.string("ref") else { throw DesktopProblem("\(action.kind.rawValue) 要给 ref") }
            let entry = try entry(ref)
            try guardOwn(entry.handle.pid, desktop)
            switch action.kind {
            case .press:
                try desktop.press(entry.handle)
                return ("按下了 \(ref)", nil)
            case .setValue:
                guard let value = action.args["value"] as? String else { throw DesktopProblem("set_value 要给 value") }
                try desktop.setValue(value, of: entry.handle)
                return ("\(ref) 填成了「\(value.count > 40 ? String(value.prefix(40)) + "…" : value)」", nil)
            default:
                try desktop.focus(entry.handle)
                return ("聚焦到了 \(ref)", nil)
            }

        case .raise:
            let window = try resolve(action.args["window"], on: desktop)
            try await desktop.raise(window)
            return ("切到了 \(window.label)", nil)

        case .writeClipboard:
            guard let text = action.args["text"] as? String else { throw DesktopProblem("write_clipboard 要给 text") }
            desktop.writeClipboard(text)
            return ("剪贴板里现在是「\(text.count > 40 ? String(text.prefix(40)) + "…" : text)」", nil)
        }
    }

    // MARK: Targets

    /// `{"id":…}`, `{"app":…,"title":…}`, a bare id or an app name — exactly one of the other apps' windows.
    func resolve(_ selector: Any?, on desktop: Desktop) throws -> DesktopWindow {
        guard let selector else { throw DesktopProblem("要给 window：{\"id\": windows 里的 id} 或 {\"app\": 应用名}") }
        let all = desktop.windows()
        var id: UInt32?
        var app: String?
        var title: String?
        if let number = selector as? NSNumber {
            id = number.uint32Value
        } else if let name = selector as? String {
            if let number = UInt32(name) { id = number } else { app = name }
        } else if let object = selector as? [String: Any] {
            id = (object["id"] as? NSNumber)?.uint32Value
            app = (object["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let id {
            guard let window = all.first(where: { $0.id == id }) else { throw DesktopProblem("没有 id 为 \(id) 的窗口；先用 windows 看现在有哪些") }
            return window
        }
        guard app != nil || title != nil else { throw DesktopProblem("window 要写 id，或者 app / title") }
        let matches = all.filter { $0.matches(app: app, title: title) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            throw DesktopProblem("没有找到这样的窗口（\([app, title].compactMap { $0 }.joined(separator: " · "))）；可能那个应用没开，或者是 Formora 自己的窗口")
        }
        let listed = matches.prefix(8).map(Self.describe).joined(separator: "\n")
        throw DesktopProblem("有 \(matches.count) 个窗口都对得上，用 id 指定一个：\n\(listed)")
    }

    /// Where pointer input lands and whose it is: a ref's centre, or x,y in the latest screenshot of the target.
    private func target(_ action: ComputerAction, on desktop: Desktop) throws -> (CGPoint, pid_t?) {
        if let ref = action.string("ref") {
            let entry = try entry(ref)
            try guardOwn(entry.handle.pid, desktop)
            guard entry.frame.width > 0, entry.frame.height > 0 else { throw DesktopProblem("\(ref) 没有大小，点不到；试试 press") }
            return (CGPoint(x: entry.frame.midX, y: entry.frame.midY), entry.handle.pid)
        }
        let point = try self.point(action, on: desktop)
        return (point, try pidUnder(point, on: desktop))
    }

    private func point(_ action: ComputerAction, on desktop: Desktop) throws -> CGPoint {
        guard let x = action.number("x"), let y = action.number("y") else { throw DesktopProblem("\(action.kind.rawValue) 要给 ref，或者 x 和 y") }
        return try latestShot(for: action.args["window"], on: desktop).point(x, y)
    }

    private func latestShot(for selector: Any?, on desktop: Desktop) throws -> Shot {
        let key = try selector.map { "w\(try resolve($0, on: desktop).id)" } ?? "screen"
        guard let shot = shots[key] else {
            throw DesktopProblem("坐标按截图的像素算，可这个目标还没截过图：先 screenshot\(selector == nil ? "" : "（带同一个 window）")")
        }
        return shot
    }

    /// Whose window is under a point — never Formora's.
    private func pidUnder(_ point: CGPoint, on desktop: Desktop) throws -> pid_t? {
        let window = desktop.window(at: point)
        if let window { try guardOwn(window.pid, desktop) }
        return window?.pid
    }

    private func guardOwn(_ pid: pid_t, _ desktop: Desktop) throws {
        if pid == desktop.ownPID { throw DesktopProblem("那是 Formora 自己的窗口，不能操作") }
    }

    static func describe(_ window: DesktopWindow) -> String {
        let frame = window.frame
        let bundle = window.bundleID.isEmpty ? "" : " \(window.bundleID)"
        return "- [id=\(window.id)] \(window.label)\(window.isFront ? "（最前面）" : "")\(bundle) (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)))"
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}
