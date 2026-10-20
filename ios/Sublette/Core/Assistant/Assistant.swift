import Foundation

/// What the assistant understood, in the renter profile's own fields. Only
/// what the message asked to change is set.
struct PreferenceChanges: Codable, Equatable {
    /// Calendar dates such as "2027-06-01".
    var startDate: String?
    var endDate: String?
    var maxRentCents: Int?
    var radiusM: Int?
    var preferences: [Preference] = []

    var isEmpty: Bool {
        startDate == nil && endDate == nil && maxRentCents == nil && radiusM == nil && preferences.isEmpty
    }
}

struct AssistantItem: Decodable, Equatable, Identifiable {
    let item: DeckItem
    /// Why the assistant picked it, in a sentence or two.
    let why: String

    var id: String { item.id }
}

struct AssistantAnswer: Decodable, Equatable {
    let understood: PreferenceChanges
    /// The understood changes in one line, such as "Private room · under $1,200".
    let summary: String
    let items: [AssistantItem]
    /// "ai" when a language model ranked them; "sublette" when the matching engine did.
    let generatedBy: String
    /// Shown under the results, always.
    let label: String
}

struct AssistantStatus: Decodable, Equatable {
    let enabled: Bool
    let label: String
}

struct AssistantQueryRequest: Encodable, Equatable {
    let message: String
}

protocol AssistantAPI: Sendable {
    func status() async throws -> AssistantStatus
    func ask(_ message: String) async throws -> AssistantAnswer
}

struct LiveAssistantAPI: AssistantAPI {
    let client: APIClient

    func status() async throws -> AssistantStatus {
        try await client.send(.assistantStatus)
    }

    func ask(_ message: String) async throws -> AssistantAnswer {
        try await client.send(.assistantQuery, body: AssistantQueryRequest(message: message))
    }
}

extension RenterProfileForm {
    /// The form with the assistant's changes in it: dates, budget and radius
    /// replaced when given, and each preference replaced by field.
    func applying(_ changes: PreferenceChanges) -> RenterProfileForm {
        var form = self
        if let start = changes.startDate, let end = changes.endDate {
            form.startDate = start
            form.endDate = end
        }
        if let rent = changes.maxRentCents {
            form.maxRentCents = rent
        }
        if let radius = changes.radiusM, var pin = form.pin {
            pin.radiusM = min(max(radius, SearchPin.minRadiusM), SearchPin.maxRadiusM)
            form.pin = pin
        }
        for preference in changes.preferences {
            form.preferences.removeAll { $0.field == preference.field }
            form.preferences.append(preference)
        }
        return form
    }
}
