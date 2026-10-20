import SwiftUI

/// One listing in the renter's deck: the first photo, the rent, the dates,
/// and why it fits.
@MainActor
struct DeckCardView: View {
    let item: DeckItem
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemotePhoto(urlString: item.listing.photos.first?.url)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.listing.rentCents.map { "\(Money.dollars($0))/mo" } ?? "")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Spacer()
                    if let label = item.band.fitLabel {
                        Text(label)
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(item.band == .strong ? Brand.textOnYellow : Brand.ink)
                            .background(item.band == .strong ? Brand.yellow : Brand.orange.opacity(0.35), in: Capsule())
                    }
                    ListingSafetyMenu(listing: item.listing)
                }
                Text([item.listing.spaceSummary, item.listing.dateSummary ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline)
                Text(item.summary)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                CommuteLines(listing: item.listing)
                Button("See everything", action: onDetails)
                    .buttonStyle(LinkButtonStyle())
                    .accessibilityIdentifier("deck-card-details")
            }
            .foregroundStyle(Brand.ink)
            .padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Brand.ink.opacity(0.08)))
        .shadow(color: Brand.ink.opacity(0.10), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Swipe right to like, left to pass")
    }
}

/// Report the listing, or block its lister.
@MainActor
struct ListingSafetyMenu: View {
    let listing: Listing
    var onBlocked: () -> Void = {}

    var body: some View {
        SafetyMenu(
            reports: [.listing(id: listing.id)],
            block: .listerOf(listingID: listing.id, name: listing.lister.firstName),
            onBlocked: onBlocked
        )
    }
}

/// Everything about one listing, opened from a card: every photo, the reasons and the details.
@MainActor
struct DeckDetailSheet: View {
    let item: DeckItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.band.fitLabel ?? "Why it might fit")
                            .font(.headline)
                        Text(item.summary)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ListingCardView(listing: item.listing)
                }
                .padding(20)
            }
            .background(Brand.cream)
            .navigationTitle(item.listing.spaceType?.title ?? "Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ListingSafetyMenu(listing: item.listing) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Brand.accentText)
                }
            }
        }
    }
}

#Preview("Card") {
    DeckCardView(item: PreviewData.deckItem, onDetails: {})
        .padding()
        .background(Brand.cream)
        .previewEnvironment()
}

#Preview("Details") {
    DeckDetailSheet(item: PreviewData.deckItem)
        .previewEnvironment()
}
