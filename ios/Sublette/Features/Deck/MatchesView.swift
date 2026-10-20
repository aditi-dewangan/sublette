import SwiftUI

/// The Matches tab. Renter mode lists matches as a renter and saved listings;
/// Lister mode lists matches on the student's own listings. A match opens its chat.
@MainActor
struct MatchesView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(SessionModel.self) private var session

    @State private var openListing: Listing?
    @State private var openChatID: String?

    private var model: MatchesModel { container.matchesModel }
    private var role: SwipeSide { appState.mode == .renter ? .renter : .lister }

    var body: some View {
        NavigationStack {
            list
                .navigationDestination(item: $openChatID) { matchID in
                    if let match = model.matches.first(where: { $0.id == matchID }) {
                        ChatView(model: model.openChat(match))
                    }
                }
        }
        .task(id: appState.chatToOpen) {
            guard let matchID = appState.chatToOpen else {
                return
            }
            appState.chatOpened()
            if await model.match(id: matchID) != nil {
                openChatID = matchID
            }
        }
    }

    private var list: some View {
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
                    Button { openChatID = match.id } label: { MatchRow(match: match) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("match-row")
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
            if !model.matches.isEmpty {
                await container.notifications.askAtFirstMatch()
            }
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
                HStack(spacing: 6) {
                    Text(match.other.firstName ?? "Your match")
                        .font(.headline)
                    if match.listing.status == .filled {
                        Text("Filled")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.ink.opacity(0.1), in: Capsule())
                    }
                }
                Text(match.listing.spaceSummary.isEmpty ? match.listing.title : match.listing.spaceSummary)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(preview)
                    .font(.footnote.weight(match.unreadCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
                    .opacity(match.unreadCount > 0 ? 1 : 0.7)
            }
            Spacer()
            if match.unreadCount > 0 {
                Text("\(match.unreadCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.textOnMagenta)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Brand.magenta, in: Capsule())
                    .accessibilityLabel("\(match.unreadCount) unread")
            }
        }
        .foregroundStyle(Brand.ink)
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let last = match.lastMessage else {
            return "Say hi and set up a tour."
        }
        return last.mine ? "You: \(last.body)" : last.body
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
    let onChat: () -> Void
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
            Spacer()
            Button("Send a message", action: onChat)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("send-a-message-button")
            Button("Keep swiping", action: onClose)
                .buttonStyle(SecondaryButtonStyle())
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
    MatchSheet(match: PreviewData.match, onChat: {}, onClose: {})
}
