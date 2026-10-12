import SwiftUI

/// The mode header on top and the current mode's tabs under it.
///
/// Renter mode (yellow): Deck, Map, Matches, Profile.
/// Lister mode (orange): Listings, Matches, Profile.
/// Switching mode swaps the whole set of tabs, with no sign-in step.
@MainActor
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ModeHeader()
            Group {
                switch appState.mode {
                case .renter: RenterTabs()
                case .lister: ListerTabs()
                }
            }
            // Each mode starts on its own first tab.
            .id(appState.mode)
            .toolbarBackground(appState.mode.accent.opacity(0.22), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .tint(Brand.ink)
        }
        .background(Brand.cream)
    }
}

/// The tabs in each mode, in order. Kept as data so tests can check them.
enum ModeTab: String, CaseIterable {
    case deck, map, listings, matches, profile

    var title: String {
        switch self {
        case .deck: return "Deck"
        case .map: return "Map"
        case .listings: return "Listings"
        case .matches: return "Matches"
        case .profile: return "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .deck: return "rectangle.stack"
        case .map: return "map"
        case .listings: return "house"
        case .matches: return "bubble.left.and.bubble.right"
        case .profile: return "person.crop.circle"
        }
    }

    static func tabs(for mode: AppMode) -> [ModeTab] {
        switch mode {
        case .renter: return [.deck, .map, .matches, .profile]
        case .lister: return [.listings, .matches, .profile]
        }
    }
}

@MainActor
private struct RenterTabs: View {
    var body: some View {
        TabView {
            ForEach(ModeTab.tabs(for: .renter), id: \.self) { tab in
                ModeTabContent(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
            }
        }
    }
}

@MainActor
private struct ListerTabs: View {
    var body: some View {
        TabView {
            ForEach(ModeTab.tabs(for: .lister), id: \.self) { tab in
                ModeTabContent(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
            }
        }
    }
}

@MainActor
private struct ModeTabContent: View {
    let tab: ModeTab

    var body: some View {
        switch tab {
        case .deck: RenterHomeView()
        case .map: MapPlaceholderView()
        case .listings: ListerHomeView()
        case .matches: MatchesPlaceholderView()
        case .profile: ProfileView()
        }
    }
}

#Preview("Renter") {
    RootView()
        .previewEnvironment(signedInAs: PreviewData.aditi)
}

#Preview("Lister") {
    let container = AppContainer.preview()
    container.appState.setMode(.lister)
    return RootView()
        .environment(container)
        .environment(container.appState)
        .environment(container.session)
        .environment(container.serverStatus)
}
