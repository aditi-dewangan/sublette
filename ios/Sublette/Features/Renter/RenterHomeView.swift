import SwiftUI

/// The first tab in Renter mode: the deck, once the renter has a search,
/// and the first step of setting one up before that.
@MainActor
struct RenterHomeView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session
    @State private var editing: PreferencesEditorModel.Step?

    private var search: RenterSearchModel { container.renterSearch }

    var body: some View {
        Group {
            if let profile = search.profile, profile.complete {
                RenterDeckView(onEditSearch: { editing = $0 })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .refreshable { await search.load() }
            }
        }
        .background(Brand.cream)
        .task(id: session.user?.id) {
            guard let userID = session.user?.id else {
                return
            }
            search.prepare(for: userID)
            container.outbox.prepare(for: userID)
            container.renterDeck.prepare(for: userID)
            container.analytics.used(.deck)
            if search.profile == nil {
                await search.load()
            }
        }
        .sheet(item: $editing) { step in
            PreferencesFlowView(model: container.makePreferencesEditor(startAt: step)) { saved in
                search.show(saved)
                Task { await container.renterDeck.reload() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = search.state {
            ErrorText(message)
            Button("Try again") { Task { await search.load() } }
                .buttonStyle(SecondaryButtonStyle())
        }
        if search.profile != nil {
            setUp
        } else if search.state == .loading || search.state == .idle {
            ProgressView()
                .tint(Brand.accentText)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    private var setUp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Brand.accentText)
                .accessibilityHidden(true)
            Text("What are you looking for?")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)
            Text("Your dates, budget, must-haves and the area you want. It takes about a minute, and you can change it any time.")
                .font(.body)
                .foregroundStyle(Brand.ink)
            Button("Set up your search") { editing = .dates }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("set-up-search-button")
        }
    }
}

#Preview("Set up") {
    RenterHomeView()
        .previewEnvironment()
}
