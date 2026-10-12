import SwiftUI

@MainActor
struct DeckPlaceholderView: View {
    var body: some View {
        PlaceholderScreen(title: "Deck", systemImage: "rectangle.stack", note: note) {
            ServerStatusCard()
        }
    }

    private var note: String {
        "Renter mode. Listings to swipe on arrive in phase 5."
    }
}

#Preview {
    DeckPlaceholderView()
        .previewEnvironment()
}
