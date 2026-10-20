import SwiftUI
import UIKit

/// The picture posted with a shared listing: its first photo, the rent, the
/// dates and the Sublette mark. 1080 × 1350, the size housing groups and
/// stories show best.
struct ShareCardView: View {
    let listing: Listing
    let photo: UIImage?

    static let size = CGSize(width: 1080, height: 1350)

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    Palette.cream
                        .overlay(PinMark(color: Palette.magenta, width: 220))
                }
            }
            .frame(width: Self.size.width, height: 860)
            .clipped()
            VStack(alignment: .leading, spacing: 18) {
                Text(listing.rentCents.map { "\(Money.dollars($0)) a month" } ?? "Sublet")
                    .font(.system(size: 92, weight: .heavy, design: .rounded))
                Text([listing.spaceSummary, listing.dateSummary ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 44, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    PinMark(color: Palette.ink, width: 52)
                    Text("Sublette · for college students")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(56)
            .frame(width: Self.size.width, height: Self.size.height - 860, alignment: .topLeading)
            .background(BrandGradient.linear)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .light)
    }

    /// Draws the card. The photo is downloaded first, since a rendered view
    /// can't wait for a picture to load.
    @MainActor
    static func render(_ listing: Listing, photo: UIImage?) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCardView(listing: listing, photo: photo))
        renderer.scale = 1
        return renderer.uiImage
    }
}

/// Share a live listing: a link (its page shows a preview in group chats)
/// and the card as a picture.
@MainActor
struct ShareListingSheet: View {
    let listing: Listing

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var card: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Group {
                        if let card {
                            Image(uiImage: card)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .accessibilityLabel("The share card for this listing")
                        } else {
                            ProgressView().frame(height: 300)
                        }
                    }
                    .shadow(color: Brand.ink.opacity(0.15), radius: 12, y: 6)
                    Text("Post it in your housing groups. The link shows the photo and price, never the address or your name.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.ink)
                        .multilineTextAlignment(.center)
                    if let url = container.shareURL(for: listing) {
                        ShareLink(
                            item: url,
                            subject: Text("A sublet on Sublette"),
                            message: Text(Self.message(for: listing)),
                            preview: SharePreview(listing.title, image: Image(uiImage: card ?? UIImage()))
                        ) {
                            Label("Share the link", systemImage: "link")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded { container.analytics.used(.shareListing) })
                    }
                    if let card {
                        ShareLink(
                            item: Image(uiImage: card),
                            preview: SharePreview(listing.title, image: Image(uiImage: card))
                        ) {
                            Label("Share the picture", systemImage: "photo")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded { container.analytics.used(.shareListing) })
                    }
                }
                .padding(20)
            }
            .background(Brand.cream)
            .navigationTitle("Share your listing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await makeCard() }
        }
        .tint(Brand.accentText)
    }

    static func message(for listing: Listing) -> String {
        let rent = listing.rentCents.map { "\(Money.dollars($0))/mo" }
        let parts = [listing.spaceSummary, rent, listing.dateSummary].compactMap { $0 }.filter { !$0.isEmpty }
        return "Subletting my place: \(parts.joined(separator: ", ")). Like it on Sublette:"
    }

    private func makeCard() async {
        var photo: UIImage?
        if let address = listing.photos.first?.url, let url = URL(string: address),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            photo = UIImage(data: data)
        }
        // Without the photo the card still works, with the mark in its place.
        card = ShareCardView.render(listing, photo: photo)
        loading = false
    }
}

#Preview("Card") {
    ShareCardView(listing: PreviewData.listing, photo: nil)
        .scaleEffect(0.3)
        .frame(width: 330, height: 410)
}

#Preview("Share sheet") {
    ShareListingSheet(listing: PreviewData.listing)
        .previewEnvironment()
}
