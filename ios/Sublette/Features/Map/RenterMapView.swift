import MapKit
import SwiftUI

/// Renter mode's Map tab: the search circle, and every listing in it as a pin.
///
/// Yellow is a strong fit, orange partial, a grey outline the rest, magenta a
/// match. Liked listings are hearts, saved ones bookmarks. Close pins group
/// into a number; tap it to zoom in.
@MainActor
struct RenterMapView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session

    @State private var position: MapCameraPosition = .automatic
    @State private var hasCentered = false
    @State private var isEditingArea = false
    @State private var draftRadius: Double = Double(SearchPin.defaultRadiusM)
    @State private var areaMessage: String?

    private var model: RenterMapModel { container.renterMap }
    private var search: RenterSearchModel { container.renterSearch }

    var body: some View {
        @Bindable var bindableMap = container.renterMap
        Group {
            if let pin = search.profile?.pin, search.profile?.complete == true {
                map(pin)
            } else if search.state == .loading || search.profile == nil {
                ProgressView().tint(Brand.accentText)
            } else {
                PlaceholderScreen(
                    title: "Map",
                    systemImage: "map",
                    note: "Set up your search on the Deck tab, and the listings around your pin show up here."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.cream)
        .task(id: session.user?.id) {
            guard let userID = session.user?.id else {
                return
            }
            search.prepare(for: userID)
            container.outbox.prepare(for: userID)
            model.prepare(for: userID)
            container.analytics.used(.map)
            if search.profile == nil {
                await search.load()
            }
            await model.load()
        }
        .sheet(item: $bindableMap.card) { card in
            MapCardSheet(card: card)
                .presentationDetents([.medium, .large])
        }
        // An alert about one listing (a price drop, closing soon) opens its card.
        .task(id: appState.listingToOpen) {
            guard let listingID = appState.listingToOpen else {
                return
            }
            await model.open(listingID)
            appState.listingOpened()
        }
    }

    private func map(_ pin: SearchPin) -> some View {
        Map(position: $position) {
                MapCircle(center: pin.coordinate.clCoordinate, radius: CLLocationDistance(pin.radiusM))
                    .foregroundStyle(Brand.yellow.opacity(0.14))
                    .stroke(Brand.ink.opacity(0.5), lineWidth: 1.5)
                Annotation("Your pin", coordinate: pin.coordinate.clCoordinate, anchor: .bottom) {
                    Image(systemName: "mappin")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Brand.ink)
                        .accessibilityLabel("Your search pin")
                }
                ForEach(model.groups) { group in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: group.latitude, longitude: group.longitude)) {
                        PinGroupView(group: group)
                            .onTapGesture { tapped(group) }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let region = MapRegion(
                    latitude: context.region.center.latitude,
                    longitude: context.region.center.longitude,
                    latitudeSpan: context.region.span.latitudeDelta,
                    longitudeSpan: context.region.span.longitudeDelta
                )
                Task { await model.show(region) }
            }
        .overlay(alignment: .top) { banners }
        .overlay(alignment: .bottom) { areaPanel(pin) }
        .onAppear {
            if !hasCentered {
                position = PinPickerView.region(pin.coordinate, radiusM: pin.radiusM)
                draftRadius = Double(pin.radiusM)
                hasCentered = true
            }
        }
    }

    private func tapped(_ group: PinGroup) {
        if group.isCluster, let region = model.region {
            // Zoom in on the group.
            let center = CLLocationCoordinate2D(latitude: group.latitude, longitude: group.longitude)
            let span = MKCoordinateSpan(latitudeDelta: region.latitudeSpan / 3, longitudeDelta: region.longitudeSpan / 3)
            withAnimation { position = .region(MKCoordinateRegion(center: center, span: span)) }
        } else if let pin = group.pins.first {
            Task { await model.open(pin.id) }
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 8) {
            if model.outbox.isOffline {
                OfflineBanner { Task { await model.outbox.flush() } }
            }
            if case .failed(let message) = model.state {
                ErrorText(message)
                    .padding(10)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))
            }
            if let message = model.cardMessage ?? areaMessage {
                ErrorText(message)
                    .padding(10)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: 10))
            }
            if model.truncated {
                Text("Showing the best 500. Zoom in to see more.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .padding(8)
                    .background(Brand.card, in: Capsule())
            }
        }
        .padding(12)
    }

    private func areaPanel(_ pin: SearchPin) -> some View {
        VStack(spacing: 10) {
            if isEditingArea {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search \(Distance.miles(Int(draftRadius))) around the middle of the map")
                        .font(.subheadline.weight(.semibold))
                    Slider(value: $draftRadius, in: Double(SearchPin.minRadiusM)...Double(SearchPin.maxRadiusM), step: 250)
                        .tint(Brand.accentText)
                    HStack {
                        Button("Cancel") {
                            isEditingArea = false
                            draftRadius = Double(pin.radiusM)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Search here") { moveArea() }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("map-search-here")
                    }
                }
                .foregroundStyle(Brand.ink)
            } else {
                Button {
                    isEditingArea = true
                } label: {
                    Label("Move pin or change radius", systemImage: "scope")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(14)
        .background(Brand.cream.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(12)
    }

    private func moveArea() {
        guard let region = model.region else {
            return
        }
        Task {
            areaMessage = nil
            let moved = await search.moveArea(
                to: Coordinate(latitude: region.latitude, longitude: region.longitude),
                radiusM: Int(draftRadius)
            )
            if moved {
                isEditingArea = false
                await model.load()
                await container.renterDeck.reload()
            } else {
                areaMessage = search.changeMessage
            }
        }
    }
}

/// One pin, or a number for several.
struct PinGroupView: View {
    let group: PinGroup

    var body: some View {
        if group.isCluster {
            Text("\(group.pins.count)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Brand.ink)
                .frame(minWidth: 34, minHeight: 34)
                .padding(.horizontal, 4)
                .background(Brand.card, in: Capsule())
                .overlay(Capsule().stroke(Brand.ink.opacity(0.6), lineWidth: 2))
                .accessibilityLabel("\(group.pins.count) listings. Tap to zoom in.")
        } else if let pin = group.pins.first {
            ListingPinView(pin: pin)
        }
    }
}

/// The mark for one listing: its color says how well it fits, its shape what
/// the renter did with it.
struct ListingPinView: View {
    let pin: MapPin

    var body: some View {
        Image(systemName: Self.symbol(for: pin.state))
            .font(.system(size: pin.state == .new ? 14 : 18, weight: .bold))
            .foregroundStyle(Self.fill(for: pin))
            .frame(width: 30, height: 30)
            .background(Self.background(for: pin), in: Circle())
            .overlay(Circle().stroke(Self.outline(for: pin), lineWidth: pin.band == .other && pin.state != .matched ? 2 : 1.5))
            .accessibilityLabel(Self.label(for: pin))
    }

    static func symbol(for state: PinState) -> String {
        switch state {
        case .new: return "circle.fill"
        case .liked: return "heart.fill"
        case .saved: return "bookmark.fill"
        case .matched: return "star.fill"
        }
    }

    /// Yellow strong, orange partial, grey outline for the rest, magenta matched.
    static func background(for pin: MapPin) -> Color {
        if pin.state == .matched {
            return Brand.magenta
        }
        switch pin.band {
        case .strong: return Brand.yellow
        case .partial: return Brand.orange
        case .other: return Brand.card
        }
    }

    static func fill(for pin: MapPin) -> Color {
        if pin.state == .matched {
            return Brand.textOnMagenta
        }
        // A new listing is a plain dot in its band's color.
        if pin.state == .new {
            return background(for: pin)
        }
        return pin.band == .other ? Brand.ink : Brand.textOnYellow
    }

    static func outline(for pin: MapPin) -> Color {
        pin.band == .other && pin.state != .matched ? Color.gray : Brand.ink.opacity(0.6)
    }

    static func label(for pin: MapPin) -> String {
        let fit = pin.band.fitLabel ?? "Listing"
        let rent = pin.rentCents.map { ", \(Money.dollars($0)) a month" } ?? ""
        switch pin.state {
        case .new: return "\(fit)\(rent)"
        case .liked: return "Liked listing, \(fit)\(rent)"
        case .saved: return "Saved listing, \(fit)\(rent)"
        case .matched: return "Matched listing\(rent)"
        }
    }
}

/// The card for a tapped pin: the same as the deck's, with like and pass.
@MainActor
struct MapCardSheet: View {
    @Environment(AppContainer.self) private var container
    let card: MapCard
    @State private var showsDetails = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DeckCardView(item: card.item) { showsDetails = true }
                switch card.state {
                case .new, .saved:
                    HStack(spacing: 24) {
                        DeckButton(systemImage: "xmark", label: "Pass") {
                            Task { await container.renterMap.pass() }
                        }
                        DeckButton(systemImage: "heart.fill", label: "Like", color: Brand.magenta) {
                            Task { await container.renterMap.like() }
                        }
                        .accessibilityIdentifier("map-like")
                    }
                case .liked:
                    Label("You liked this. If the lister likes you back, you'll match.", systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                case .matched:
                    VStack(alignment: .leading, spacing: 6) {
                        Label("You matched", systemImage: "star.fill")
                            .font(.headline)
                        if let address = card.item.listing.address {
                            Text(address)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                    .foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(Brand.cream)
        .sheet(isPresented: $showsDetails) {
            DeckDetailSheet(item: card.item)
        }
    }
}

#Preview("Map") {
    RenterMapView()
        .previewEnvironment()
}

#Preview("Pins") {
    HStack(spacing: 12) {
        ForEach([MapPin.preview(.strong, .new), .preview(.partial, .liked), .preview(.other, .new), .preview(.strong, .saved), .preview(.strong, .matched)]) { pin in
            ListingPinView(pin: pin)
        }
    }
    .padding()
    .background(Brand.cream)
}

extension MapPin {
    static func preview(_ band: ScoreBand, _ state: PinState) -> MapPin {
        MapPin(
            id: "\(band.rawValue)-\(state.rawValue)", latitude: 47.66, longitude: -122.31,
            exact: state == .matched, score: band == .strong ? 90 : band == .partial ? 60 : 30,
            band: band, state: state, rentCents: 105_000
        )
    }
}
