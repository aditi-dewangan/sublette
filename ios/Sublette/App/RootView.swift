import SwiftUI

/// The mode header on top and the current mode's tabs under it.
///
/// Renter mode (yellow): Deck, Map, Matches, Profile.
/// Lister mode (orange): Listings, Renters, Matches, Profile.
/// Switching mode swaps the whole set of tabs, with no sign-in step.
@MainActor
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var outbox = container.outbox
        VStack(spacing: 0) {
            ModeHeader()
            ModeTabs(mode: appState.mode)
                // Each mode starts on its own first tab.
                .id(appState.mode)
        }
        .background(Brand.cream)
        .sheet(item: $outbox.latestMatch) { match in
            MatchSheet(match: match) {
                container.matchesModel.show(match)
                container.outbox.latestMatch = nil
            }
        }
    }
}

/// The tabs in each mode, in order. Kept as data so tests can check them.
enum ModeTab: String, CaseIterable {
    case deck, map, listings, renters, matches, profile

    var title: String {
        switch self {
        case .deck: return "Deck"
        case .map: return "Map"
        case .listings: return "Listings"
        case .renters: return "Renters"
        case .matches: return "Matches"
        case .profile: return "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .deck: return "rectangle.stack"
        case .map: return "map"
        case .listings: return "house"
        case .renters: return "person.2"
        case .matches: return "bubble.left.and.bubble.right"
        case .profile: return "person.crop.circle"
        }
    }

    static func tabs(for mode: AppMode) -> [ModeTab] {
        switch mode {
        case .renter: return [.deck, .map, .matches, .profile]
        case .lister: return [.listings, .renters, .matches, .profile]
        }
    }
}

@MainActor
private struct ModeTabs: View {
    let mode: AppMode

    var body: some View {
        TabView {
            ForEach(ModeTab.tabs(for: mode), id: \.self) { tab in
                ModeTabContent(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .toolbarBackground(mode.accent.opacity(0.22), for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
            }
        }
        .tint(Brand.ink)
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
        case .renters: ListerDeckView()
        case .matches: MatchesView()
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
