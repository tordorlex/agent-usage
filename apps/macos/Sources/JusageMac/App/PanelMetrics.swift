import CoreGraphics

/// Shared geometry for the popover and the SwiftUI panel it hosts. The two must
/// agree, so both read these values.
enum PanelMetrics {
    static let width: CGFloat = 400
    static let height: CGFloat = 580
    /// Horizontal padding around the scrolling column.
    static let outerPadding: CGFloat = 10
    /// Vertical gap between cards.
    static let sectionSpacing: CGFloat = 8
}
