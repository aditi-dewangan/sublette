import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// One server endpoint. Every path the app calls is declared in this file and
/// nowhere else, and is checked against docs/contract/endpoints.json.
struct Endpoint: Equatable {
    let method: HTTPMethod
    let path: String
    /// Every endpoint except health and sign-in needs a verified account.
    var requiresAuth: Bool = true
    /// Added after the path as `?name=value`.
    var query: [URLQueryItem] = []
}

extension Endpoint {
    static let health = Endpoint(method: .get, path: "/health", requiresAuth: false)

    // Sign-in. These three are the only /v1 endpoints that need no account.
    static let requestCode = Endpoint(method: .post, path: "/v1/auth/request-code", requiresAuth: false)
    static let verifyCode = Endpoint(method: .post, path: "/v1/auth/verify", requiresAuth: false)
    static let refreshTokens = Endpoint(method: .post, path: "/v1/auth/refresh", requiresAuth: false)

    // The signed-in user's own account.
    static let me = Endpoint(method: .get, path: "/v1/me")
    static let updateMe = Endpoint(method: .patch, path: "/v1/me")
    static let deleteMe = Endpoint(method: .delete, path: "/v1/me")

    static let presignUpload = Endpoint(method: .post, path: "/v1/uploads/presign")

    // Lister mode.
    static let createListing = Endpoint(method: .post, path: "/v1/listings")

    static func myListings(cursor: String?) -> Endpoint {
        Endpoint(
            method: .get,
            path: "/v1/me/listings",
            query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        )
    }

    static func listing(_ id: String) -> Endpoint {
        Endpoint(method: .get, path: "/v1/listings/\(id)")
    }

    static func updateListing(_ id: String) -> Endpoint {
        Endpoint(method: .patch, path: "/v1/listings/\(id)")
    }

    static func listingStatus(_ id: String) -> Endpoint {
        Endpoint(method: .post, path: "/v1/listings/\(id)/status")
    }

    // Renter mode.
    static let renterProfile = Endpoint(method: .get, path: "/v1/me/renter-profile")
    static let saveRenterProfile = Endpoint(method: .put, path: "/v1/me/renter-profile")

    // The deck (phase 4 on the server; the screens are phase 5).
    static func deckListings(limit: Int) -> Endpoint {
        Endpoint(method: .get, path: "/v1/deck/listings", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    static let deckDiagnostics = Endpoint(method: .get, path: "/v1/deck/diagnostics")

    // Swiping and matches.
    static let swipe = Endpoint(method: .post, path: "/v1/swipes")
    static let undoSwipe = Endpoint(method: .post, path: "/v1/swipes/undo")
    static let matches = Endpoint(method: .get, path: "/v1/matches")
    static let savedListings = Endpoint(method: .get, path: "/v1/saved")

    static func saveListing(_ id: String) -> Endpoint {
        Endpoint(method: .post, path: "/v1/saved/\(id)")
    }

    static func unsaveListing(_ id: String) -> Endpoint {
        Endpoint(method: .delete, path: "/v1/saved/\(id)")
    }

    static func interestedRenters(_ listingID: String) -> Endpoint {
        Endpoint(method: .get, path: "/v1/listings/\(listingID)/deck/renters")
    }

    // The renter's map.
    static func mapListings(bbox: String) -> Endpoint {
        Endpoint(method: .get, path: "/v1/map/listings", query: [URLQueryItem(name: "bbox", value: bbox)])
    }

    static func mapListing(_ id: String) -> Endpoint {
        Endpoint(method: .get, path: "/v1/map/listings/\(id)")
    }

    // Chat (phase 7).
    static func match(_ id: String) -> Endpoint {
        Endpoint(method: .get, path: "/v1/matches/\(id)")
    }

    static func messages(matchID: String, before: String?) -> Endpoint {
        Endpoint(
            method: .get,
            path: "/v1/matches/\(matchID)/messages",
            query: before.map { [URLQueryItem(name: "before", value: $0)] } ?? []
        )
    }

    static func sendMessage(matchID: String) -> Endpoint {
        Endpoint(method: .post, path: "/v1/matches/\(matchID)/messages")
    }

    static func markRead(matchID: String) -> Endpoint {
        Endpoint(method: .post, path: "/v1/matches/\(matchID)/read")
    }

    static func checklist(matchID: String) -> Endpoint {
        Endpoint(method: .patch, path: "/v1/matches/\(matchID)/checklist")
    }

    static func filled(matchID: String) -> Endpoint {
        Endpoint(method: .post, path: "/v1/matches/\(matchID)/filled")
    }

    // Push notifications.
    static let registerDevice = Endpoint(method: .post, path: "/v1/devices")

    static func unregisterDevice(token: String) -> Endpoint {
        Endpoint(method: .delete, path: "/v1/devices/\(token)")
    }

    /// The live connection: a WebSocket, opened with the same token as any request.
    static let liveEvents = Endpoint(method: .get, path: "/v1/ws")

    // Trust and safety (phase 8).
    static let report = Endpoint(method: .post, path: "/v1/reports")
    static let block = Endpoint(method: .post, path: "/v1/blocks")
    static let blocks = Endpoint(method: .get, path: "/v1/blocks")

    static func unblock(userID: String) -> Endpoint {
        Endpoint(method: .delete, path: "/v1/blocks/\(userID)")
    }

    static let acceptTerms = Endpoint(method: .post, path: "/v1/me/terms")

    /// Web pages the app opens in the browser.
    static let termsPage = Endpoint(method: .get, path: "/terms", requiresAuth: false)
    static let privacyPage = Endpoint(method: .get, path: "/privacy", requiresAuth: false)

    // Release (phase 9).
    static let event = Endpoint(method: .post, path: "/v1/events")
    static let diagnostics = Endpoint(method: .post, path: "/v1/diagnostics")
    static let useReferral = Endpoint(method: .post, path: "/v1/me/referral")

    // The assistant (phase 10).
    static let assistantStatus = Endpoint(method: .get, path: "/v1/assistant")
    static let assistantQuery = Endpoint(method: .post, path: "/v1/assistant/query")

    /// The public page a shared listing link opens.
    static func listingShare(_ id: String) -> Endpoint {
        Endpoint(method: .get, path: "/l/\(id)", requiresAuth: false)
    }
}
