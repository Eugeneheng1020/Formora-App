import AppKit
import SwiftUI

/// The brake while an Agent operates the computer (7j, C3): a bar across the top of the screen, above every window,
/// saying so with 停止; ⌘⎋ anywhere; and the user's own mouse or keys in another app — any of them stops every run
/// that is operating. Input Formora posted itself, and its echoes just after, don't count; neither does the user
/// working in Formora's own window (reading the thread, scrolling) — only ⌘⎋ or 停止 stop from there.
@MainActor
final class ComputerGuard {
    var onStop: (UUID) -> Void = { _ in }

    private var active: Set<UUID> = []
    private var panel: NSPanel?
    private var monitors: [Any] = []

    func set(_ id: UUID, operating: Bool) {
        if operating {
            active.insert(id)
        } else {
            active.remove(id)
        }
        if active.isEmpty { tearDown() } else { show() }
    }

    private func stopAll() {
        let ids = active
        active = []
        tearDown()
        for id in ids { onStop(id) }
    }

    private func show() {
        guard panel == nil else { return }
        let size = CGSize(width: 440, height: 40)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: StopBar { [weak self] in self?.stopAll() })
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 10))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .scrollWheel,
                                           .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            let isEscape = Self.isCommandEscape(event)
            let isOurs = Self.isOurs(event)
            MainActor.assumeIsolated {
                guard let guardian = Self.current else { return }
                if isEscape || (!isOurs && Date.now.timeIntervalSince(ComputerInput.lastPosted) > 0.5) { guardian.stopAll() }
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if Self.isCommandEscape(event) {
                MainActor.assumeIsolated { Self.current?.stopAll() }
                return nil
            }
            return event
        }) {
            monitors.append(local)
        }
        Self.current = self
    }

    private func tearDown() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        if Self.current === self { Self.current = nil }
    }

    /// The guard the event monitors report to (one app, one bar).
    private static var current: ComputerGuard?

    nonisolated private static func isCommandEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53 && event.modifierFlags.contains(.command)
    }

    nonisolated private static func isOurs(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == ComputerInput.tag
    }
}

/// The bar itself: a dot, what is going on, 停止.
private struct StopBar: View {
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.alert.color).frame(width: 7, height: 7)
            Text("Formora 正在操作电脑").font(FormoraFont.ui(12.5, weight: 600)).foregroundStyle(Palette.ink.color)
            Text("动一下鼠标或键盘也会停").font(FormoraFont.ui(11)).foregroundStyle(Palette.inkFaint.color)
            Spacer(minLength: 4)
            Button(action: stop) {
                Text("停止（⌘ + Esc）")
                    .font(FormoraFont.ui(11.5, weight: 600))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Capsule().fill(Palette.alert.color))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(width: 440, height: 40)
        .background(Capsule().fill(Palette.surfaceRaised.color))
        .overlay(Capsule().strokeBorder(Palette.lineStrong.color, lineWidth: 1))
    }
}
