import CoreGraphics

/// Layout numbers from design spec v4 §3 (`main-view-v4.html:631–760`).
enum ShellMetrics {
    static let railWidth: CGFloat = 84
    static let listWidth: CGFloat = 300
    static let footerHeight: CGFloat = 46
    static var leftPaneWidth: CGFloat { railWidth + listWidth }

    static let defaultWindowSize = CGSize(width: 1280, height: 800)
    static let minimumWindowSize = CGSize(width: 1024, height: 700)

    /// Design: 16. Pushed down to clear the window's traffic-light buttons (deviation D1).
    static let railTopPadding: CGFloat = 38
}
