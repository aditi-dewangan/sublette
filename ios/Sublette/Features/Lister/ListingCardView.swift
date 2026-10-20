import SwiftUI
import UIKit

/// A listing laid out the way renters see it. Used by the editor's preview and
/// by the lister's own listing page.
@MainActor
struct ListingCardView: View {
    let listing: Listing
    /// Photos picked in the editor and not saved yet, by key.
    var localImages: [String: Data] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            photoPager
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(listing.rentCents.map { "\(Money.dollars($0))/mo" } ?? "Rent not set")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Spacer()
                    if let dates = listing.dateSummary {
                        Text(dates)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                if !listing.spaceSummary.isEmpty {
                    Text(listing.spaceSummary)
                        .font(.subheadline)
                }
                if listing.depositCents > 0 {
                    Text("\(Money.dollars(listing.depositCents)) deposit")
                        .font(.footnote)
                        .opacity(0.75)
                }
            }
            .foregroundStyle(Brand.ink)

            if !listing.amenities.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(listing.amenities, id: \.self) { amenity in
                            Text(amenity)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Brand.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Brand.cream, in: Capsule())
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let staying = listing.housematesStaying {
                    detail(
                        "person.2",
                        staying == 0 ? "Nobody else staying" : "\(staying) housemate\(staying == 1 ? "" : "s") staying"
                    )
                }
                if let household = listing.householdGender, (listing.housematesStaying ?? 0) > 0 {
                    detail("person.3", household.livesWith)
                }
                if let note = listing.housematesNote, !note.isEmpty {
                    Text("“\(note)”")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(Brand.ink)
                }
                if let pets = listing.petsAllowed {
                    detail("pawprint", pets ? "Pets welcome" : "No pets")
                }
                if let smoking = listing.smokingAllowed {
                    detail("smoke", smoking ? "Smokers welcome" : "No smoking")
                }
                if listing.minStayDays > 0 {
                    detail("calendar", "Stay at least \(listing.minStayDays / 7) weeks")
                }
                if listing.genderPreference != .anyone {
                    detail("person", "Prefers \(listing.genderPreference.title.lowercased())")
                }
                if listing.sameSchoolOnly {
                    detail("graduationcap", "\(listing.lister.schoolName) students only")
                }
                if let consent = listing.landlordConsent {
                    detail(
                        consent ? "checkmark.shield" : "exclamationmark.triangle",
                        consent ? "Landlord approved subletting" : "Landlord hasn't approved subletting yet"
                    )
                }
            }

            HStack(spacing: 10) {
                AvatarView(urlString: listing.lister.photoUrl, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(listing.lister.firstName ?? "Lister")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                    if listing.lister.verified {
                        VerifiedBadge(schoolName: listing.lister.schoolName)
                    }
                }
            }
        }
        .padding(16)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func detail(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(Brand.ink)
    }

    @ViewBuilder
    private var photoPager: some View {
        if listing.photos.isEmpty {
            ZStack {
                Brand.cream
                Label("No photos yet", systemImage: "photo")
                    .font(.subheadline)
                    .foregroundStyle(Brand.ink.opacity(0.6))
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            TabView {
                ForEach(listing.photos) { photo in
                    photoView(photo)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
            .tabViewStyle(.page)
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityLabel("\(listing.photos.count) photos")
        }
    }

    @ViewBuilder
    private func photoView(_ photo: ListingPhoto) -> some View {
        if let data = localImages[photo.key], let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let address = photo.url, let url = URL(string: address) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Brand.cream
                }
            }
        } else {
            Brand.cream
        }
    }
}

/// "Live", "Paused", "Draft" and so on, as a small colored label.
struct StatusChip: View {
    let status: ListingStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(Brand.ink.opacity(status == .draft ? 0.3 : 0), lineWidth: 1))
    }

    private var background: Color {
        switch status {
        case .active: return Brand.yellow
        case .paused: return Brand.orange
        case .filled: return Brand.magenta
        case .draft, .expired, .removed: return Brand.card
        }
    }

    private var foreground: Color {
        switch status {
        case .filled: return Brand.textOnMagenta
        case .active: return Brand.textOnYellow
        case .paused: return Brand.textOnOrange
        case .draft, .expired, .removed: return Brand.ink
        }
    }
}

#Preview("Card") {
    ScrollView {
        ListingCardView(listing: PreviewData.listing)
            .padding()
    }
    .background(Brand.cream)
}

#Preview("Status chips") {
    HStack {
        ForEach(ListingStatus.allCases, id: \.self) { status in
            StatusChip(status: status)
        }
    }
    .padding()
    .background(Brand.cream)
}
