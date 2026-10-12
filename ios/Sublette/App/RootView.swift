import SwiftUI

/// The mode header on top, and the four tabs under it. The first tab is the
/// deck in Renter mode and the student's own listings in Lister mode.
@MainActor
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ModeHeader()
            TabView {
                Group {
                    if appState.mode == .lister {
                        ListerHomeView()
                    } else {
                        DeckPlaceholderView()
                    }
                }
                .tabItem {
                    if appState.mode == .lister {
                        Label("Listings", systemImage: "house")
                    } else {
                        Label("Deck", systemImage: "rectangle.stack")
                    }
                }
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
