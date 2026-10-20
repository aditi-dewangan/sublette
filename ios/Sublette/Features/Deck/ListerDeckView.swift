import SwiftUI

/// Lister mode's Renters tab: pick a listing, then like or pass on the renters
/// who liked it. A like makes a match.
@MainActor
struct ListerDeckView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session

    private var model: ListerDeckModel { container.listerDeck }

    var body: some View {
        VStack(spacing: 12) {
            header
            if model.outbox.isOffline {
                OfflineBanner { Task { await model.outbox.flush() } }
            }
            if let message = model.message {
                ErrorText(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(Brand.cream)
        .task(id: session.user?.id) {
            if let userID = session.user?.id {
                container.outbox.prepare(for: userID)
                model.prepare(for: userID)
            }
            await model.load()
        }
        .refreshable { await model.load() }
    }

    private var header: some View {
        HStack {
            Text("Interested renters")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)
            Spacer()
            if model.listings.count > 1 {
                Menu {
                    ForEach(model.listings) { listing in
                        Button(listing.title) { Task { await model.select(listing.id) } }
                    }
                } label: {
                    Label(model.selectedListing?.title ?? "Listing", systemImage: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                }
                .accessibilityIdentifier("lister-deck-listing-menu")
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = model.state, model.renters.isEmpty {
            VStack(spacing: 14) {
                ErrorText(message)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 40)
        } else if model.state == .loaded && model.listings.isEmpty {
            note(
                "Publish a listing first",
                "Renters who like your place show up here. Post one from the Listings tab."
            )
        } else if !model.renters.isEmpty {
            VStack(spacing: 16) {
                SwipeCardStack(
                    items: model.renters,
                    onLike: { Task { await model.like() } },
                    onPass: { Task { await model.pass() } }
                ) { renter in
                    RenterCardView(item: renter)
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 18) {
                    DeckButton(systemImage: "arrow.uturn.backward", label: "Undo", size: 48) {
                        Task { await model.undo() }
                    }
                    .disabled(!model.canUndo)
                    .opacity(model.canUndo ? 1 : 0.4)
                    DeckButton(systemImage: "xmark", label: "Pass") { Task { await model.pass() } }
                    DeckButton(systemImage: "heart.fill", label: "Like", color: Brand.magenta) {
                        Task { await model.like() }
                    }
                    .accessibilityIdentifier("lister-deck-like")
                }
            }
        } else if model.state == .loading || model.state == .idle {
            ProgressView()
                .tint(Brand.magenta)
                .padding(.top, 60)
        } else {
            note(
                "No one new yet",
                "When a renter likes \(model.selectedListing?.title ?? "your listing"), they show up here. Pull down to check again."
            )
        }
    }

    private func note(_ title: String, _ text: String) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Brand.magenta)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text(text)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Brand.ink)
            .padding(.top, 50)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A renter who liked the listing, as the lister sees them. Never their pin.
@MainActor
struct RenterCardView: View {
    let item: InterestedRenter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AvatarView(urlString: item.renter.photoUrl, size: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.renter.firstName ?? "A student")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    if item.renter.verified {
                        VerifiedBadge(schoolName: item.renter.schoolName)
                    }
                    if let year = item.renter.year, let program = item.renter.program {
                        Text("\(year.title) · \(program)")
                            .font(.subheadline)
                    }
                }
                Spacer(minLength: 0)
                SafetyMenu(
                    reports: [.person(id: item.renter.id, name: item.renter.firstName)],
                    block: .person(id: item.renter.id, name: item.renter.firstName)
                )
            }
            if let dates = Self.dates(item) {
                Label(dates, systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
            }
            if let bio = item.renter.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(item.fits, id: \.self) { fit in
                    Label(fit, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Brand.ink)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Brand.ink.opacity(0.08)))
        .shadow(color: Brand.ink.opacity(0.10), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Swipe right to like, left to pass")
    }

    static func dates(_ item: InterestedRenter) -> String? {
        guard let start = CalendarDate.date(from: item.startDate),
              let end = CalendarDate.date(from: item.endDate)
        else {
            return nil
        }
        let style = Date.FormatStyle().month(.abbreviated).day()
        return "Wants \(start.formatted(style)) – \(end.formatted(style))"
    }
}

#Preview("Lister deck") {
    ListerDeckView()
        .previewEnvironment()
}

#Preview("Renter card") {
    RenterCardView(item: PreviewData.interestedRenter)
        .frame(height: 420)
        .padding()
        .background(Brand.cream)
        .previewEnvironment()
}
