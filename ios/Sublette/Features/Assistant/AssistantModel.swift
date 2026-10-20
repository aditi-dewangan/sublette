import Foundation
import Observation

/// The Assistant screen: describe a place in plain words, get a short list.
/// Whether the screen exists at all is the server's call (`GET /v1/assistant`),
/// so it can be turned off without an app update.
@MainActor
@Observable
final class AssistantModel {
    enum State: Equatable {
        case idle
        case asking
        case answered
        case failed(String)
    }

    private(set) var isEnabled = false
    private(set) var label = "Suggestions are generated automatically and drawn only from listings on Sublette."
    private(set) var state: State = .idle
    private(set) var answer: AssistantAnswer?
    private(set) var liked: Set<String> = []
    private(set) var savedPreferences = false
    var message = ""

    @ObservationIgnored private let api: AssistantAPI
    @ObservationIgnored private let outbox: SwipeOutbox
    @ObservationIgnored private let makeSwipeID: () -> String
    /// Saves the understood changes into the renter's search.
    @ObservationIgnored var saveChanges: ((PreferenceChanges) async -> Bool)?
    /// A listing liked here leaves the deck too.
    @ObservationIgnored var onLiked: ((String) -> Void)?

    static let examples = [
        "Furnished room for the summer under $1,200",
        "Private bathroom, no smokers, within 2 miles",
        "Whole place from June 15 to August 20",
    ]

    init(api: AssistantAPI, outbox: SwipeOutbox, makeSwipeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.api = api
        self.outbox = outbox
        self.makeSwipeID = makeSwipeID
    }

    /// Asks the server whether the screen should show. Offline, the last
    /// answer stands.
    func refreshStatus() async {
        guard let status = try? await api.status() else {
            return
        }
        isEnabled = status.enabled
        label = status.label
    }

    func ask() async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state != .asking else {
            return
        }
        state = .asking
        savedPreferences = false
        do {
            answer = try await api.ask(text)
            state = .answered
        } catch let error as APIError where error.serverCode == "assistant_off" {
            isEnabled = false
            state = .failed(error.userMessage)
        } catch {
            state = .failed((error as? APIError)?.userMessage ?? APIError.unreachable.userMessage)
        }
    }

    /// Likes a suggestion, the same as swiping right on it (queued offline).
    func like(_ suggestion: AssistantItem) async {
        guard !liked.contains(suggestion.id) else {
            return
        }
        liked.insert(suggestion.id)
        await outbox.send(SwipeRequest(listingId: suggestion.id, renterId: nil, action: .like, swipeId: makeSwipeID()))
        onLiked?(suggestion.id)
    }

    /// Saves the understood preferences to the renter's search.
    func saveUnderstood() async {
        guard let changes = answer?.understood, !changes.isEmpty, let saveChanges else {
            return
        }
        savedPreferences = await saveChanges(changes)
    }

    func reset() {
        message = ""
        answer = nil
        liked = []
        state = .idle
        savedPreferences = false
    }
}
