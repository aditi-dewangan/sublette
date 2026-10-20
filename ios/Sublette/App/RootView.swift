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
        .fullScreenCover(item: $outbox.latestMatch) { match in
            MatchSheet(
                match: match,
                onChat: {
                    container.matchesModel.show(match)
                    container.outbox.latestMatch = nil
                    appState.openChat(matchID: match.id, role: match.role)
                },
                onClose: {
                    container.matchesModel.show(match)
                    container.outbox.latestMatch = nil
                }
            )
            .task { await container.notifications.askAtFirstMatch() }
        }
        // initial: a tap that launched the app arrives before this view exists.
        .onChange(of: container.notifications.target, initial: true) { _, target in
            guard let target else {
                return
            }
            container.notifications.target = nil
            switch target {
            case .chat(let matchID, let role): appState.openChat(matchID: matchID, role: role)
            case .deck: appState.openDeck()
            case .listings: appState.openListings()
            case .listing(let id): appState.openListing(id)
            case .renters: appState.openRenters()
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
    @Environment(AppState.self) private var appState
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.tab) {
            ForEach(ModeTab.tabs(for: mode), id: \.self) { tab in
                ModeTabContent(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
                    .badge(tab == .matches ? unread : 0)
                    .toolbarBackground(mode.accent.opacity(0.22), for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
            }
        }
        .tint(Brand.ink)
    }

    private var unread: Int {
        container.matchesModel.unreadCount(as: mode == .renter ? .renter : .lister)
    }
}

@MainActor
private struct ModeTabContent: View {
    let tab: ModeTab

    var body: some View {
        switch tab {
        case .deck: RenterHomeView()
        case .map: RenterMapView()
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
