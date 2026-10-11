import SwiftUI

/// The Sublette palette. Values are checked against docs/contract/design-tokens.json.
///
/// Most of the screen is cream and ink. The three brand colors mark actions and status.
enum Brand {
    /// Renter mode accent, strong-match pins, highlights.
    static let yellow = Color(hex: 0xFFC629)
    /// Primary buttons, the like action, the match moment.
    static let magenta = Color(hex: 0xD6177A)
    /// Lister mode accent, notifications, secondary buttons.
    static let orange = Color(hex: 0xFF7A1A)
    /// Body text and icons.
    static let ink = Color(hex: 0x2A1422)
    /// App background and cards.
    static let cream = Color(hex: 0xFFF8EC)

    // Text colors that pass the WCAG 4.5:1 minimum on each background.
    // White text fails on yellow and on orange, so it is never used there.
    static let textOnYellow = ink
    static let textOnOrange = ink
    static let textOnMagenta = Color.white
    static let textOnCream = ink
}

extension Color {
    /// A color from a hex value such as `0xFFC629`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
