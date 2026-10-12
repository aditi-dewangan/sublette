import CoreLocation
import Foundation

struct Coordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

struct LocatedAddress: Equatable {
    let coordinate: Coordinate
    /// The address as Apple understood it, to show for confirmation.
    let formatted: String
}

enum AddressLookupError: Error, Equatable {
    /// The lookup worked, but nothing matched what was typed.
    case notFound
    /// Apple's service could not be reached or refused the request.
    case unavailable
}

/// Turns a typed address into a point on the map.
protocol AddressLocating: Sendable {
    func locate(_ address: String) async throws -> LocatedAddress
}

/// Apple's own geocoder. Free, but it needs a connection and limits how often
/// one phone may ask.
struct AppleAddressLocator: AddressLocating {
    func locate(_ address: String) async throws -> LocatedAddress {
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await CLGeocoder().geocodeAddressString(address)
        } catch let error as CLError where error.code == .geocodeFoundNoResult
            || error.code == .geocodeFoundPartialResult {
            throw AddressLookupError.notFound
        } catch {
            throw AddressLookupError.unavailable
        }
        guard let placemark = placemarks.first, let location = placemark.location else {
            throw AddressLookupError.notFound
        }
        let parts = [placemark.name, placemark.locality, placemark.administrativeArea, placemark.postalCode]
        return LocatedAddress(
            coordinate: Coordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            formatted: parts.compactMap { $0 }.joined(separator: ", ")
        )
    }
}
