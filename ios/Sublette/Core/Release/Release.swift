import Foundation

/// Features the app reports as used, for the business numbers on the admin
/// page. The server keeps the same list (`FEATURES` in services/analytics.py).
enum AppFeature: String, Codable, CaseIterable {
    case deck
    case map
    case matches
    case chat
    case saved
    case undo
    case notifyMe = "notify_me"
    case biggerArea = "bigger_area"
    case shareListing = "share_listing"
    case referral
    case settings
    case report
    case block
}

struct EventRequest: Encodable, Equatable {
    let name: String
    var feature: AppFeature?

    static let appOpened = EventRequest(name: "app_opened")

    static func used(_ feature: AppFeature) -> EventRequest {
        EventRequest(name: "feature_used", feature: feature)
    }
}

/// One crash or hang report from MetricKit.
struct CrashRequest: Codable, Equatable {
    let kind: String
    let appVersion: String
    let osVersion: String
    let payload: String
}

struct ReferralRequest: Encodable, Equatable {
    let code: String
}

/// Analytics, crash reports and referral codes.
protocol ReleaseAPI: Sendable {
    func send(_ event: EventRequest) async throws
    func send(_ crash: CrashRequest) async throws
    func useReferral(code: String) async throws -> User
}

struct LiveReleaseAPI: ReleaseAPI {
    let client: APIClient

    func send(_ event: EventRequest) async throws {
        try await client.sendNoContent(.event, body: event)
    }

    func send(_ crash: CrashRequest) async throws {
        try await client.sendNoContent(.diagnostics, body: crash)
    }

    func useReferral(code: String) async throws -> User {
        try await client.send(.useReferral, body: ReferralRequest(code: code))
    }
}
