import Foundation
import Observation

/// The renter's map: pins in the visible area, the card for a tapped pin,
/// and like or pass from that card.
@MainActor
@Observable
final class RenterMapModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        /// The server wants the profile or search finished first.
        case notReady(String)
    }

    private(set) var pins: [MapPin] = []
    private(set) var truncated = false
    private(set) var state: LoadState = .idle
    private(set) var region: MapRegion?
    /// The card for the tapped pin.
    var card: MapCard?
    private(set) var cardMessage: String?
    private(set) var isOpening = false

    let outbox: SwipeOutbox
    private let api: MapAPI
    private let makeSwipeID: () -> String
    private var userID: String?
    /// Tells the deck a listing was swiped here, so it isn't shown there again.
    var onSwiped: ((String) -> Void)?

    init(api: MapAPI, outbox: SwipeOutbox, makeSwipeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.api = api
        self.outbox = outbox
        self.makeSwipeID = makeSwipeID
    }

    /// Pins grouped for the current zoom.
    var groups: [PinGroup] {
        guard let region else {
            return []
        }
        return PinClusterer.groups(pins, latitudeSpan: region.latitudeSpan, longitudeSpan: region.longitudeSpan)
    }

    func prepare(for userID: String) {
        guard userID != self.userID else {
            return
        }
        self.userID = userID
        pins = []
        card = nil
        state = .idle
    }

    /// The map stopped moving: load the pins for what is visible.
    func show(_ region: MapRegion) async {
        self.region = region
        await load()
    }

    func load() async {
        guard let region else {
            return
        }
        state = .loading
        do {
            let page = try await api.pins(in: region)
            // A swipe still waiting on the phone wins over what the server knows.
            let pending = outbox.pendingStates
            pins = page.items.compactMap { pin in
                guard let action = pending[pin.id] else {
                    return pin
                }
                guard action == .like else {
                    return nil
                }
                var liked = pin
                liked.state = .liked
                return liked
            }
            truncated = page.truncated
            state = .loaded
        } catch let error as APIError where error.status == 409 {
            state = .notReady(error.userMessage)
        } catch let error as APIError where error == .cancelled {
            // The map moved again; the newer load takes over.
        } catch {
            // Offline: the pins already shown stay.
            state = .failed((error as? APIError)?.userMessage ?? APIError.unreachable.userMessage)
        }
    }

    func open(_ pinID: String) async {
        cardMessage = nil
        isOpening = true
        defer { isOpening = false }
        do {
            var opened = try await api.card(listingID: pinID)
            if let pin = pins.first(where: { $0.id == pinID }), pin.state == .liked {
                opened.state = .liked
            }
            card = opened
        } catch {
            cardMessage = (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
        }
    }

    func like() async {
        await swipe(.like)
    }

    func pass() async {
        await swipe(.pass)
    }

    private func swipe(_ action: SwipeAction) async {
        guard let card else {
            return
        }
        let listingID = card.item.id
        self.card = nil
        if action == .like {
            if let index = pins.firstIndex(where: { $0.id == listingID }) {
                pins[index].state = .liked
            }
        } else {
            pins.removeAll { $0.id == listingID }
        }
        onSwiped?(listingID)
        await outbox.send(SwipeRequest(listingId: listingID, renterId: nil, action: action, swipeId: makeSwipeID()))
        if let refused = outbox.message {
            cardMessage = refused
            outbox.clearMessage()
            await load()
        }
    }
}
