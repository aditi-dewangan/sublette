import Foundation
import MapKit

/// Finds a school's campus on the map, for the "My campus" shortcut.
protocol CampusLocating: Sendable {
    /// Throws `AddressLookupError.notFound` when Maps has no such place, and
    /// `.unavailable` when Apple's service can't be reached.
    func locateCampus(named schoolName: String) async throws -> Coordinate
}

/// Apple Maps search. Free, but it needs a connection. Nothing about any one
/// school is built in: the school's own name is the search.
struct AppleCampusLocator: CampusLocating {
    func locateCampus(named schoolName: String) async throws -> Coordinate {
        let name = schoolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AddressLookupError.notFound
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = .pointOfInterest
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw AddressLookupError.notFound
        } catch {
            throw AddressLookupError.unavailable
        }
        guard let place = response.mapItems.first?.placemark.coordinate else {
            throw AddressLookupError.notFound
        }
        return Coordinate(latitude: place.latitude, longitude: place.longitude)
    }
}
