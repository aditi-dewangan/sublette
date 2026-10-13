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
                    Text("\(item.score)% fit")
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Brand.yellow, in: Capsule())
                        .accessibilityLabel("Fit score \(item.score) out of 100")
                }
                Text([item.listing.spaceSummary, item.listing.dateSummary ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.reasons, id: \.self) { reason in
                        Label(reason, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                    }
                }
                Button("See everything", action: onDetails)
                    .buttonStyle(LinkButtonStyle())
                    .accessibilityIdentifier("deck-card-details")
            }
            .foregroundStyle(Brand.ink)
            .padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Brand.ink.opacity(0.08)))
        .shadow(color: Brand.ink.opacity(0.10), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Swipe right to like, left to pass")
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
                        Text("Why it fits · \(item.score)%")
                            .font(.headline)
                        ForEach(item.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                        }
                    }
                    .foregroundStyle(Brand.ink)
                    ListingCardView(listing: item.listing)
                }
                .padding(20)
            }
            .background(Brand.cream)
            .navigationTitle(item.listing.spaceType?.title ?? "Listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Brand.magenta)
                }
            }
        }
    }
}

#Preview("Card") {
    DeckCardView(item: PreviewData.deckItem, onDetails: {})
        .padding()
        .background(Brand.cream)
}

#Preview("Details") {
    DeckDetailSheet(item: PreviewData.deckItem)
}
