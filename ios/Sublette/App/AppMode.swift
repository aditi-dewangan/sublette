import SwiftUI

/// The two sides of one account. Renter mode looks for a place; Lister mode offers one.
enum AppMode: String, CaseIterable, Identifiable {
    case renter
    case lister

    var id: String { rawValue }

    var title: String {
        switch self {
        case .renter: return "Renter"
        case .lister: return "Lister"
        }
    }

    /// Yellow in Renter mode, orange in Lister mode, so the user always knows which side they are on.
    var accent: Color {
        switch self {
        case .renter: return Brand.yellow
        case .lister: return Brand.orange
        }
    }

    /// Ink on both accents. White text fails contrast on yellow and on orange.
    var textOnAccent: Color {
        switch self {
        case .renter: return Brand.textOnYellow
        case .lister: return Brand.textOnOrange
        }
    }
}
