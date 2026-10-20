import Foundation
import Observation

/// Travel times from listings to the renter's saved places, shown on cards:
/// "Campus: 18 min by transit · 25 min walk".
///
/// Asked only for cards on screen, one trip at a time, and every answer is
/// kept (also offline), so Apple's request limit is never near. A listing
/// with no answer shows nothing: the card still has the miles from the pin.
@MainActor
@Observable
final class CommuteModel {
    /// What one listing-to-place trip takes, by each way that has a route.
    struct Times: Codable, Equatable {
        var transit: Int?
        var walking: Int?
        var driving: Int?
    }

    static let maxPlaces = 2
    /// Walking further than this isn't worth showing.
    static let longestWalk = 45

    private(set) var places: [SavedPlace] = []
    private(set) var times: [String: Times] = [:]

    @ObservationIgnored private let estimator: CommuteEstimating
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let cache: OfflineStoring?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var asking: Set<String> = []
    @ObservationIgnored private var queue: Task<Void, Never>?

    init(estimator: CommuteEstimating, preferences: Preferences, cache: OfflineStoring?) {
        self.estimator = estimator
        self.preferences = preferences
        self.cache = cache
    }

    /// Loads this account's places and remembered times.
    func prepare(for accountID: String) {
        guard accountID != self.accountID else {
            return
        }
        self.accountID = accountID
        places = preferences.savedPlaces(for: accountID)
        times = cache?.load([String: Times].self, key: CacheKey.commute(accountID)) ?? [:]
    }

    func reset() {
        accountID = nil
        places = []
        times = [:]
    }

    // MARK: - Places

    var canAddPlace: Bool { places.count < Self.maxPlaces }

    func add(_ place: SavedPlace) {
        guard canAddPlace, let accountID else {
            return
        }
        places.append(place)
        preferences.setSavedPlaces(places, for: accountID)
    }

    func remove(_ place: SavedPlace) {
        guard let accountID else {
            return
        }
        places.removeAll { $0.id == place.id }
        preferences.setSavedPlaces(places, for: accountID)
        times = times.filter { !$0.key.hasSuffix(":\(place.id)") }
        save()
    }

    // MARK: - Times

    /// One line per saved place with an answer, such as
    /// "Campus: 18 min by transit · 25 min walk".
    func lines(for listing: Listing) -> [String] {
        places.compactMap { place in
            guard let found = times[Self.key(listing.id, place.id)] else {
                return nil
            }
            let parts = Self.describe(found)
            return parts.isEmpty ? nil : "\(place.name): \(parts.joined(separator: " · "))"
        }
    }

    static func describe(_ times: Times) -> [String] {
        var parts: [String] = []
        if let transit = times.transit {
            parts.append("\(transit) min by transit")
        }
        if let walking = times.walking, walking <= longestWalk {
            parts.append("\(walking) min walk")
        }
        if parts.isEmpty, let driving = times.driving {
            parts.append("\(driving) min drive")
        }
        return parts
    }

    /// Works out the times for one listing, unless they're known.
    func load(for listing: Listing) async {
        guard let point = Self.point(of: listing) else {
            return
        }
        for place in places {
            let key = Self.key(listing.id, place.id)
            guard times[key] == nil, !asking.contains(key) else {
                continue
            }
            asking.insert(key)
            let found = await ask(from: point, to: place.coordinate)
            asking.remove(key)
            // A place removed meanwhile, or another account: drop the answer.
            guard places.contains(where: { $0.id == place.id }) else {
                continue
            }
            times[key] = found
            save()
        }
    }

    /// One trip at a time, so a fast swipe through the deck never floods Apple.
    private func ask(from: Coordinate, to: Coordinate) async -> Times {
        let previous = queue
        let estimator = estimator
        let task = Task { () -> Times in
            await previous?.value
            var found = Times()
            found.transit = try? await estimator.minutes(from: from, to: to, by: .transit)
            found.walking = try? await estimator.minutes(from: from, to: to, by: .walking)
            if found.transit == nil, (found.walking ?? Int.max) > Self.longestWalk {
                found.driving = try? await estimator.minutes(from: from, to: to, by: .driving)
            }
            return found
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private func save() {
        guard let accountID else {
            return
        }
        cache?.save(times, key: CacheKey.commute(accountID))
    }

    /// The exact point for the owner or a matched renter, else the public one.
    static func point(of listing: Listing) -> Coordinate? {
        if let latitude = listing.latitude, let longitude = listing.longitude {
            return Coordinate(latitude: latitude, longitude: longitude)
        }
        if let latitude = listing.publicLatitude, let longitude = listing.publicLongitude {
            return Coordinate(latitude: latitude, longitude: longitude)
        }
        return nil
    }

    static func key(_ listingID: String, _ placeID: String) -> String {
        "\(listingID):\(placeID)"
    }
}
