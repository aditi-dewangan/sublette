import Foundation

/// One pin, or several close together shown as a number.
struct PinGroup: Identifiable, Equatable {
    let id: String
    let pins: [MapPin]
    let latitude: Double
    let longitude: Double

    var isCluster: Bool {
        pins.count > 1
    }
}

/// Groups pins that would overlap at the current zoom, so the map draws a few
/// dozen marks instead of hundreds.
enum PinClusterer {
    /// The visible width is cut into this many cells each way; pins sharing a cell group.
    static let cellsAcross = 9.0
    /// Closer than this (about 400 meters across the screen), every pin stands alone.
    static let showAllBelowSpan = 0.004

    static func groups(_ pins: [MapPin], latitudeSpan: Double, longitudeSpan: Double) -> [PinGroup] {
        // Matched listings always stand alone, so they are never hidden in a number.
        let alone = pins.filter { $0.state == .matched || latitudeSpan < showAllBelowSpan }
        let aloneIDs = Set(alone.map(\.id))
        let rest = pins.filter { !aloneIDs.contains($0.id) }

        var groups = alone.map { PinGroup(id: $0.id, pins: [$0], latitude: $0.latitude, longitude: $0.longitude) }
        let cellHeight = max(latitudeSpan / cellsAcross, 1e-9)
        let cellWidth = max(longitudeSpan / cellsAcross, 1e-9)
        var cells: [String: [MapPin]] = [:]
        for pin in rest {
            let key = "\(Int((pin.latitude / cellHeight).rounded(.down)))/\(Int((pin.longitude / cellWidth).rounded(.down)))"
            cells[key, default: []].append(pin)
        }
        for members in cells.values {
            let sorted = members.sorted { $0.id < $1.id }
            if sorted.count == 1, let pin = sorted.first {
                groups.append(PinGroup(id: pin.id, pins: [pin], latitude: pin.latitude, longitude: pin.longitude))
            } else {
                let count = Double(sorted.count)
                groups.append(PinGroup(
                    id: "cluster-" + (sorted.first?.id ?? ""),
                    pins: sorted,
                    latitude: sorted.map(\.latitude).reduce(0, +) / count,
                    longitude: sorted.map(\.longitude).reduce(0, +) / count
                ))
            }
        }
        return groups.sorted { $0.id < $1.id }
    }
}
