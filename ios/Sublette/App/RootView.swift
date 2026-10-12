import SwiftUI

/// The mode header on top, and the four tabs under it.
struct RootView: View {
    var body: some View {
        VStack(spacing: 0) {
            ModeHeader()
            TabView {
                DeckPlaceholderView()
                    .tabItem { Label("Deck", systemImage: "rectangle.stack") }
                MapPlaceholderView()
                    .tabItem { Label("Map", systemImage: "map") }
                MatchesPlaceholderView()
                    .tabItem { Label("Matches", systemImage: "bubble.left.and.bubble.right") }
                ProfileView()
                    .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            }
        }
        .background(Brand.cream)
    }
}

#Preview {
    RootView()
        .previewEnvironment(signedInAs: PreviewData.aditi)
}
