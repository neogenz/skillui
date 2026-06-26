import SwiftUI

/// Centralized visual constants — keep the panel glanceable and consistent.
enum Theme {
    static let panelWidth: CGFloat = 380
    static let panelMaxHeight: CGFloat = 520

    static let amber = Color(red: 0.95, green: 0.62, blue: 0.10)   // "update available"
    static let cardCorner: CGFloat = 10
    static let rowVPad: CGFloat = 8
    static let rowHPad: CGFloat = 12

    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var subtle: Color { Color(nsColor: .quaternaryLabelColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }
}

extension Color {
    /// Soft tinted chip background.
    func chipFill(_ opacity: Double = 0.14) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(self.opacity(opacity))
    }
}
