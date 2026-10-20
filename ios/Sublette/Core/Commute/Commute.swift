import Foundation
import MapKit

/// A place the renter goes often, such as campus or the office. Kept on the
/// phone only: it says where someone spends their days, so it never goes to
/// Sublette's server.
struct SavedPlace: Codable, Equatable, Identifiable {
    var id: String
    /// "Campus", "Work", or the renter's own word.
    var name: String
    /// The address as Apple understood it.
    var address: String
    var latitude: Double
    var longitude: Double

    var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

enum CommuteMode: String, Codable, CaseIterable {
    case transit
    case walking
    case driving
}

/// How long a trip takes. A protocol so tests don't call Apple.
protocol CommuteEstimating: Sendable {
    /// Minutes from `from` to `to`. Throws when there's no route or no answer.
    func minutes(from: Coordinate, to: Coordinate, by mode: CommuteMode) async throws -> Int
}

enum CommuteError: Error, Equatable {
    case noRoute
}

/// Apple Maps travel times, worked out on the phone: free, and nothing about
/// the trip reaches Sublette. Apple limits how often one app may ask, so
/// `CommuteModel` asks only for cards on screen and remembers every answer.
struct AppleCommuteEstimator: CommuteEstimating {
    func minutes(from: Coordinate, to: Coordinate, by mode: CommuteMode) async throws -> Int {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.location))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.location))
        switch mode {
        case .transit: request.transportType = .transit
        case .walking: request.transportType = .walking
        case .driving: request.transportType = .automobile
        }
        do {
            let answer = try await MKDirections(request: request).calculateETA()
            return max(1, Int((answer.expectedTravelTime / 60).rounded()))
        } catch {
            throw CommuteError.noRoute
        }
    }
}

private extension Coordinate {
    var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
