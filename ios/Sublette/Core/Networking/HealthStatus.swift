import Foundation

/// The body of `GET /health`.
struct HealthStatus: Decodable, Equatable {
    struct Database: Decodable, Equatable {
        let reachable: Bool
        let postgis: String?
    }

    let status: String
    let version: String
    let environment: String
    let database: Database
}

/// Anything that can ask the server how it is. Lets screens be tested without a network.
protocol HealthChecking: Sendable {
    func health() async throws -> HealthStatus
}
