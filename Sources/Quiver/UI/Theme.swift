import SwiftUI

/// Visual constants. Surface recipe mirrors OpenUsage / macOS System Settings: an opaque
/// bright "tray" (`.textBackgroundColor`) with borderless grouped cards lifted off it by
/// the system's own `.fill.quaternary` — no hand-tuned hexes, no strokes, adapts light/dark.
enum Theme {
    static let panelWidth: CGFloat = 380
    static let panelMaxHeight: CGFloat = 520

    static let amber = Color(red: 0.95, green: 0.62, blue: 0.10)   // "update available"

    // MARK: Surfaces
    /// The opaque page behind the cards (white in light, near-black in dark).
    static var traySurface: Color { Color(nsColor: .textBackgroundColor) }
    /// Subtle system fill that lifts a card off the tray — the System Settings grouped box.
    static let cardFill = AnyShapeStyle(.fill.quaternary)
    static let cardCorner: CGFloat = 12
    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cardCorner, style: .continuous) }

    static var subtle: Color { Color(nsColor: .quaternaryLabelColor) }
    static var hairline: Color { Color(nsColor: .separatorColor) }

    // MARK: Roles
    static let hover = Color.primary.opacity(0.06)
    static let statusOK = Color.green
    static let statusWarn = Color.yellow

    static let rowVPad: CGFloat = Spacing.md
    static let rowHPad: CGFloat = Spacing.lg

    /// 8pt-grid spacing scale.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }
}

extension View {
    /// Borderless grouped-card surface: opaque tray base + `.fill.quaternary`, rounded.
    func cardSurface() -> some View {
        background {
            Theme.cardShape.fill(Theme.traySurface)
                .overlay { Theme.cardShape.fill(Theme.cardFill) }
        }
    }
}

extension Color {
    /// Soft tinted chip background.
    func chipFill(_ opacity: Double = 0.14) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(self.opacity(opacity))
    }
}
