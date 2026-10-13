import Foundation

/// strong (75+), partial (50 to 74) or other. Pins are colored by it.
enum ScoreBand: String, Decodable, Equatable {
    case strong
    case partial
    case other

    /// What a card says instead of a number. Nothing for "other".
    var fitLabel: String? {
        switch self {
        case .strong: return "Great fit"
        case .partial: return "Good fit"
        case .other: return nil
        }
    }
}

/// Where a listing stands for this renter.
enum PinState: String, Decodable, Equatable {
    case new
    case liked
    case saved
    case matched
}

/// One listing on the map. Small on purpose: hundreds arrive at once.
struct MapPin: Decodable, Equatable, Identifiable {
    let id: String
    /// The public point, or the real one for a matched listing (`exact`).
    let latitude: Double
    let longitude: Double
    let exact: Bool
    let score: Int
    let band: ScoreBand
    var state: PinState
    let rentCents: Int?
}

struct MapPage: Decodable, Equatable {
    let items: [MapPin]
    /// More pins matched than the server sends; the weakest were left out.
    let truncated: Bool
}

/// What tapping a pin opens: the deck's card, and the pin's state.
struct MapCard: Decodable, Equatable {
    let item: DeckItem
    var state: PinState
}

/// The visible part of the map, in degrees.
struct MapRegion: Equatable {
    var latitude: Double
    var longitude: Double
    var latitudeSpan: Double
    var longitudeSpan: Double

    /// `min_lng,min_lat,max_lng,max_lat` for the server, kept inside the world.
    var bboxParameter: String {
        let halfLat = latitudeSpan / 2
        let halfLng = longitudeSpan / 2
        let west = max(-180, longitude - halfLng)
        let east = min(180, longitude + halfLng)
        let south = max(-90, latitude - halfLat)
        let north = min(90, latitude + halfLat)
        return [west, south, east, north].map { String(format: "%.5f", $0) }.joined(separator: ",")
    }
}

extension MapCard: Identifiable {
    var id: String { item.id }
}

protocol MapAPI: Sendable {
    func pins(in region: MapRegion) async throws -> MapPage
    func card(listingID: String) async throws -> MapCard
}

struct LiveMapAPI: MapAPI {
    let client: APIClient

    func pins(in region: MapRegion) async throws -> MapPage {
        try await client.send(.mapListings(bbox: region.bboxParameter))
    }

    func card(listingID: String) async throws -> MapCard {
        try await client.send(.mapListing(listingID))
    }
}
