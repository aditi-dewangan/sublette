import SwiftUI

@MainActor
struct DeckPlaceholderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        PlaceholderScreen(title: "Deck", systemImage: "rectangle.stack", note: note) {
            ServerStatusCard()
        }
    }

    private var note: String {
        switch appState.mode {
        case .renter:
            return "Renter mode. Listings to swipe on arrive in phase 5."
        case .lister:
            return "Lister mode. Renters who liked your listing arrive in phase 5."
        }
    }
}

#Preview {
    DeckPlaceholderView()
        .previewEnvironment()
}
