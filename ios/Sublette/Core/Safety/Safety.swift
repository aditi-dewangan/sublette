import Foundation

/// Why something is being reported. The server keeps the same list.
enum ReportReason: String, Codable, CaseIterable, Identifiable {
    case scam
    case harassment
    case inappropriate
    case fake
    case discrimination
    case unsafe
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scam: return "Scam or asking for money"
        case .harassment: return "Harassment or threats"
        case .inappropriate: return "Inappropriate content"
        case .fake: return "Fake or misleading"
        case .discrimination: return "Discrimination"
        case .unsafe: return "Feels unsafe"
        case .other: return "Something else"
        }
    }
}

/// Something a student can report: a profile, a listing or a message.
enum ReportSubject: Identifiable, Equatable {
    case person(id: String, name: String?)
    case listing(id: String)
    case message(id: String, senderName: String?)

    var id: String {
        switch self {
        case .person(let id, _): return "user:\(id)"
        case .listing(let id): return "listing:\(id)"
        case .message(let id, _): return "message:\(id)"
        }
    }

    /// "Report Sam", "Report this listing", "Report this message".
    var title: String {
        switch self {
        case .person(_, let name): return "Report \(name ?? "this person")"
        case .listing: return "Report this listing"
        case .message: return "Report this message"
        }
    }

    var request: (target: String, id: String) {
        switch self {
        case .person(let id, _): return ("user", id)
        case .listing(let id): return ("listing", id)
        case .message(let id, _): return ("message", id)
        }
    }
}

/// Someone to block: by their id, or as the lister of a listing (a listing
/// card doesn't carry the lister's id).
enum BlockSubject: Identifiable, Equatable {
    case person(id: String, name: String?)
    case listerOf(listingID: String, name: String?)

    var id: String {
        switch self {
        case .person(let id, _): return "user:\(id)"
        case .listerOf(let id, _): return "listing:\(id)"
        }
    }

    var name: String? {
        switch self {
        case .person(_, let name), .listerOf(_, let name): return name
        }
    }

    /// "Block Sam", or "Block this lister".
    var title: String {
        switch self {
        case .person(_, let name): return "Block \(name ?? "this person")"
        case .listerOf(_, let name): return "Block \(name ?? "this lister")"
        }
    }
}

struct ReportRequest: Encodable, Equatable {
    let target: String
    let id: String
    let reason: ReportReason
    let details: String?
}

struct ReportReceipt: Decodable, Equatable {
    let id: String
    let target: String
    let reason: ReportReason
    let status: String
    let createdAt: Date
}

/// Optional fields are left out of the JSON, so exactly one is sent.
struct BlockRequest: Encodable, Equatable {
    var userId: String?
    var listingId: String?

    init(_ subject: BlockSubject) {
        switch subject {
        case .person(let id, _): userId = id
        case .listerOf(let id, _): listingId = id
        }
    }
}

struct BlockedPerson: Decodable, Equatable, Identifiable {
    let userId: String
    let firstName: String?
    let photoUrl: String?
    let blockedAt: Date

    var id: String { userId }
}

struct BlockPage: Decodable, Equatable {
    let items: [BlockedPerson]
}

struct TermsRequest: Encodable, Equatable {
    let version: String
}

/// Reporting, blocking and accepting the terms.
protocol SafetyAPI: Sendable {
    func report(_ request: ReportRequest) async throws -> ReportReceipt
    func block(_ subject: BlockSubject) async throws
    func blocked() async throws -> BlockPage
    func unblock(userID: String) async throws
    func acceptTerms(version: String) async throws -> User
}

struct LiveSafetyAPI: SafetyAPI {
    let client: APIClient

    func report(_ request: ReportRequest) async throws -> ReportReceipt {
        try await client.send(.report, body: request)
    }

    func block(_ subject: BlockSubject) async throws {
        try await client.sendNoContent(.block, body: BlockRequest(subject))
    }

    func blocked() async throws -> BlockPage {
        try await client.send(.blocks)
    }

    func unblock(userID: String) async throws {
        try await client.sendNoContent(.unblock(userID: userID))
    }

    func acceptTerms(version: String) async throws -> User {
        try await client.send(.acceptTerms, body: TermsRequest(version: version))
    }
}
