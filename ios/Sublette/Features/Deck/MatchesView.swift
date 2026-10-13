import SwiftUI

/// The Matches tab. Renter mode lists matches as a renter and saved listings;
/// Lister mode lists matches on the student's own listings. Chat is phase 7.
@MainActor
struct MatchesView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(SessionModel.self) private var session

    @State private var openListing: Listing?

    private var model: MatchesModel { container.matchesModel }
    private var role: SwipeSide { appState.mode == .renter ? .renter : .lister }

    var body: some View {
        List {
            if case .failed(let message) = model.state {
                ErrorText(message)
                    .listRowBackground(Color.clear)
            }
            if let message = model.message {
                ErrorText(message)
                    .listRowBackground(Color.clear)
            }
            Section("Matches") {
                let mine = model.matches(as: role)
                if mine.isEmpty {
                    Text(role == .renter
                        ? "When a lister likes you back, the match shows up here."
                        : "When you like a renter who liked your place, the match shows up here.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.ink.opacity(0.75))
                }
                ForEach(mine) { match in
                    Button { openListing = match.listing } label: { MatchRow(match: match) }
                        .buttonStyle(.plain)
                }
            }
            if role == .renter {
                Section("Saved") {
                    if model.saved.isEmpty {
                        Text("Tap the bookmark on a card to keep it here.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.ink.opacity(0.75))
                    }
                    ForEach(model.saved) { listing in
                        Button { openListing = listing } label: { SavedRow(listing: listing) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Unsave", role: .destructive) {
                                    Task {
                                        await model.unsave(listing)
                                        await container.renterDeck.reload()
                                    }
                                }
                            }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.cream)
        .refreshable { await model.load() }
        .task(id: session.user?.id) {
            if let userID = session.user?.id {
                model.prepare(for: userID)
                container.outbox.prepare(for: userID)
            }
            await model.load()
        }
        .sheet(item: $openListing) { listing in
            NavigationStack {
                ScrollView {
                    ListingCardView(listing: listing)
                        .padding(20)
                }
                .background(Brand.cream)
                .navigationTitle(listing.spaceType?.title ?? "Listing")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { openListing = nil }
                            .tint(Brand.magenta)
                    }
                }
            }
        }
    }
}

private struct MatchRow: View {
    let match: Match

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(urlString: match.other.photoUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.other.firstName ?? "Your match")
                    .font(.headline)
                Text(match.listing.spaceSummary.isEmpty ? match.listing.title : match.listing.spaceSummary)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("Chat arrives in the next update.")
                    .font(.footnote)
                    .opacity(0.7)
            }
            Spacer()
        }
        .foregroundStyle(Brand.ink)
        .contentShape(Rectangle())
    }
}

private struct SavedRow: View {
    let listing: Listing

    var body: some View {
        HStack(spacing: 12) {
            RemotePhoto(urlString: listing.photos.first?.url)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.rentCents.map { "\(Money.dollars($0))/mo" } ?? "")
                    .font(.headline)
                Text([listing.spaceSummary, listing.dateSummary ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(Brand.ink)
        .contentShape(Rectangle())
    }
}

/// The plain "It's a match" screen. The designed one comes in phase 9.
@MainActor
struct MatchSheet: View {
    let match: Match
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("It's a match!")
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                .foregroundStyle(Brand.magenta)
            HStack(spacing: -16) {
                AvatarView(urlString: match.renter.photoUrl, size: 96)
                AvatarView(urlString: match.lister.photoUrl, size: 96)
            }
            Text("You and \(match.other.firstName ?? "your match") both said yes to \(match.listing.title).")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink)
            Text("Chat arrives in the next update. Find this match in the Matches tab.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink.opacity(0.75))
            Spacer()
            Button("Keep swiping", action: onClose)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("keep-swiping-button")
        }
        .padding(28)
        .background(Brand.cream)
    }
}

#Preview("Matches") {
    MatchesView()
        .previewEnvironment()
}

#Preview("It's a match") {
    MatchSheet(match: PreviewData.match, onClose: {})
}
