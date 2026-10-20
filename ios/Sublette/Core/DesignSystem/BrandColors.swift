import SwiftUI
import UIKit

/// The raw Sublette palette. Values are checked against docs/contract/design-tokens.json.
/// Screens use `Brand`, which picks the right one for light and dark mode.
enum Palette {
    static let yellow = Color(hex: 0xFFC629)
    static let magenta = Color(hex: 0xD6177A)
    static let orange = Color(hex: 0xFF7A1A)
    static let ink = Color(hex: 0x2A1422)
    static let cream = Color(hex: 0xFFF8EC)
    /// Dark mode: cards and fields, one step up from the ink background.
    static let inkRaised = Color(hex: 0x3A2431)
    /// Dark mode: magenta text and links. Magenta itself is 3.5:1 on ink, too dim to read.
    static let pink = Color(hex: 0xFF6FB0)
}

/// The colors screens use. Most of the screen is cream and ink (ink and cream
/// in dark mode); the three brand colors mark actions and status.
enum Brand {
    /// Renter mode accent, strong-match pins, highlights. The same in dark mode.
    static let yellow = Palette.yellow
    /// Primary buttons, the like action, the match moment.
    static let magenta = Palette.magenta
    /// Lister mode accent, notifications, secondary buttons.
    static let orange = Palette.orange
    /// Body text and icons: ink, or cream in dark mode.
    static let ink = Color(light: Palette.ink, dark: Palette.cream)
    /// The app's background: cream, or ink in dark mode.
    static let cream = Color(light: Palette.cream, dark: Palette.ink)
    /// Cards, fields and bubbles: white, or a lighter ink in dark mode.
    static let card = Color(light: .white, dark: Palette.inkRaised)
    /// Links and magenta text that must be readable: magenta, or pink in dark mode.
    static let accentText = Color(light: Palette.magenta, dark: Palette.pink)

    // Text colors that pass the WCAG 4.5:1 minimum on each background, in
    // both modes. White text fails on yellow and on orange, so it is never
    // used there, and yellow and orange keep dark ink text in dark mode too.
    static let textOnYellow = Palette.ink
    static let textOnOrange = Palette.ink
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

    /// One color in light mode and another in dark mode.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
