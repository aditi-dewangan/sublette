import Foundation

/// One chat message, as the server sends it.
struct ChatMessage: Codable, Equatable, Identifiable {
    let id: String
    /// The id the app made up when sending it.
    let messageId: String?
    let matchId: String
    let senderId: String
    /// True when the signed-in student sent it.
    let mine: Bool
    let body: String
    let createdAt: Date
}

/// Oldest first. Ask again with `before` set to the first id for older ones.
struct MessagePage: Decodable, Equatable {
    let items: [ChatMessage]
    let hasMore: Bool
}

/// The steps to a sublet, shared by both sides of a match.
struct Checklist: Codable, Equatable {
    var tourDone: Bool
    var landlordConsentConfirmed: Bool
    var datesAgreed: Bool
    var subleaseSigned: Bool
    var updatedAt: Date?

    static let empty = Checklist(
        tourDone: false, landlordConsentConfirmed: false, datesAgreed: false, subleaseSigned: false
    )

    enum Step: String, CaseIterable, Identifiable {
        case tourDone
        case landlordConsentConfirmed
        case datesAgreed
        case subleaseSigned

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tourDone: return "Tour done"
            case .landlordConsentConfirmed: return "Landlord's consent confirmed"
            case .datesAgreed: return "Dates agreed"
            case .subleaseSigned: return "Sublease signed"
            }
        }
    }

    subscript(step: Step) -> Bool {
        get {
            switch step {
            case .tourDone: return tourDone
            case .landlordConsentConfirmed: return landlordConsentConfirmed
            case .datesAgreed: return datesAgreed
            case .subleaseSigned: return subleaseSigned
            }
        }
        set {
            switch step {
            case .tourDone: tourDone = newValue
            case .landlordConsentConfirmed: landlordConsentConfirmed = newValue
            case .datesAgreed: datesAgreed = newValue
            case .subleaseSigned: subleaseSigned = newValue
            }
        }
    }

    var doneCount: Int { Step.allCases.filter { self[$0] }.count }
}

/// Each side's "Filled". The lister's closes the listing; both make a completed sublet.
struct Filled: Codable, Equatable {
    let renterConfirmed: Bool
    let listerConfirmed: Bool
    let completed: Bool

    static let none = Filled(renterConfirmed: false, listerConfirmed: false, completed: false)

    func confirmed(by role: SwipeSide) -> Bool {
        role == .renter ? renterConfirmed : listerConfirmed
    }
}

/// Something the server tells an open app about, over the live connection.
enum LiveEvent: Decodable, Equatable {
    /// Connected. Anything missed while away should be reloaded now.
    case ready
    case message(ChatMessage, Match)
    /// A match is new or changed (checklist, "Filled").
    case match(Match, isNew: Bool)
    /// A kind this version of the app doesn't know yet.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, message, match, newMatch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "ready":
            self = .ready
        case "message":
            self = .message(
                try container.decode(ChatMessage.self, forKey: .message),
                try container.decode(Match.self, forKey: .match)
            )
        case "match":
            self = .match(
                try container.decode(Match.self, forKey: .match),
                isNew: try container.decodeIfPresent(Bool.self, forKey: .newMatch) ?? false
            )
        default:
            self = .unknown
        }
    }
}

struct MessageRequest: Encodable, Equatable {
    let body: String
    /// Made up on the phone, so a message sent twice is stored once.
    let messageId: String
}

/// Only the steps that changed are sent.
struct ChecklistChange: Encodable, Equatable {
    var tourDone: Bool?
    var landlordConsentConfirmed: Bool?
    var datesAgreed: Bool?
    var subleaseSigned: Bool?

    init(_ step: Checklist.Step, _ value: Bool) {
        switch step {
        case .tourDone: tourDone = value
        case .landlordConsentConfirmed: landlordConsentConfirmed = value
        case .datesAgreed: datesAgreed = value
        case .subleaseSigned: subleaseSigned = value
        }
    }
}

enum PushEnvironment: String, Encodable {
    case sandbox
    case production
    /// A simulator on the developer's Mac. A local server pushes into it with
    /// `xcrun simctl push`, so notifications can be tried with no Apple account.
    case simulator

    /// Debug builds get their tokens from Apple's sandbox.
    static var current: PushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

struct DeviceRequest: Encodable, Equatable {
    let token: String
    let environment: PushEnvironment
}

protocol ChatAPI: Sendable {
    func match(id: String) async throws -> Match
    func messages(matchID: String, before: String?) async throws -> MessagePage
    func send(matchID: String, _ request: MessageRequest) async throws -> ChatMessage
    func markRead(matchID: String) async throws
    func updateChecklist(matchID: String, _ change: ChecklistChange) async throws -> Match
    func confirmFilled(matchID: String) async throws -> Match
    func registerDevice(_ request: DeviceRequest) async throws
    func unregisterDevice(token: String) async throws
}

struct LiveChatAPI: ChatAPI {
    let client: APIClient

    func match(id: String) async throws -> Match {
        try await client.send(.match(id))
    }

    func messages(matchID: String, before: String?) async throws -> MessagePage {
        try await client.send(.messages(matchID: matchID, before: before))
    }

    func send(matchID: String, _ request: MessageRequest) async throws -> ChatMessage {
        try await client.send(.sendMessage(matchID: matchID), body: request)
    }

    func markRead(matchID: String) async throws {
        try await client.sendNoContent(.markRead(matchID: matchID))
    }

    func updateChecklist(matchID: String, _ change: ChecklistChange) async throws -> Match {
        try await client.send(.checklist(matchID: matchID), body: change)
    }

    func confirmFilled(matchID: String) async throws -> Match {
        try await client.send(.filled(matchID: matchID))
    }

    func registerDevice(_ request: DeviceRequest) async throws {
        try await client.sendNoContent(.registerDevice, body: request)
    }

    func unregisterDevice(token: String) async throws {
        try await client.sendNoContent(.unregisterDevice(token: token))
    }
}
