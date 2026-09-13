import AppKit
import SwiftUI

/// Sizes the window for what it shows: the launch flow is a fixed card-sized window; the main view is
/// resizable (min 1024×700) and, in the default profile, remembers its frame.
struct WindowShaper: NSViewRepresentable {
    enum Mode: Equatable { case launch, main }

    let mode: Mode
    /// Only the default profile autosaves the main frame, so test runs never move the user's window.
    let remembersFrame: Bool

    static let frameAutosaveName = "FormoraMainWindow"

    final class Coordinator {
        var appliedMode: Mode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window, coordinator: context.coordinator) }
    }

    private func apply(to window: NSWindow?, coordinator: Coordinator) {
        guard let window, coordinator.appliedMode != mode else { return }
        coordinator.appliedMode = mode
        switch mode {
        case .launch:
            window.setFrameAutosaveName("")
            window.styleMask.remove(.resizable)
            window.contentMinSize = LaunchMetrics.windowSize
            window.contentMaxSize = LaunchMetrics.windowSize
            window.setContentSize(LaunchMetrics.windowSize)
            window.center()
        case .main:
            window.styleMask.insert(.resizable)
            window.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.contentMinSize = ShellMetrics.minimumWindowSize
            if !(remembersFrame && window.setFrameUsingName(Self.frameAutosaveName)) {
                window.setContentSize(ShellMetrics.defaultWindowSize)
                window.center()
            }
            if remembersFrame { window.setFrameAutosaveName(Self.frameAutosaveName) }
        }
    }
}
