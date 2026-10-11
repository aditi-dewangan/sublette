import Foundation
import Observation

/// Asks the server for `/health` and turns the answer into something a screen can show.
///
/// The app must stay usable when the server cannot be reached, so every failure
/// becomes a state here; nothing is thrown at the screen.
@MainActor
@Observable
final class ServerStatusModel {
    enum State: Equatable {
        case idle
        case loading
        /// The server and its database both answered.
        case healthy(HealthStatus)
        /// The server answered, but something behind it is down.
        case degraded(message: String)
        /// No answer at all.
        case unreachable
    }

    private(set) var state: State = .idle
    let configuration: AppConfiguration
    private let health: HealthChecking

    init(health: HealthChecking, configuration: AppConfiguration) {
        self.health = health
        self.configuration = configuration
    }

    var title: String {
        switch state {
        case .idle, .loading: return "Checking the server"
        case .healthy: return "Server is up"
        case .degraded: return "Server has a problem"
        case .unreachable: return "Can't reach the server"
        }
    }

    var detail: String {
        switch state {
        case .idle, .loading:
            return "Asking \(serverName) how it is."
        case .healthy(let status):
            return "Version \(status.version), \(status.environment). Database reachable."
        case .degraded(let message):
            return message
        case .unreachable:
            if configuration.environment == .local {
                return "Nothing answered at \(serverName). Start the server with `make dev`, then check again."
            }
            return "Nothing answered at \(serverName). Check your connection, then check again."
        }
    }

    var serverName: String {
        configuration.apiBaseURL.absoluteString
    }

    var isLoading: Bool {
        state == .loading
    }

    func refresh() async {
        state = .loading
        do {
            let status = try await health.health()
            if status.database.reachable {
                state = .healthy(status)
            } else {
                state = .degraded(message: "The server is running but cannot reach its database.")
            }
        } catch APIError.cancelled {
            state = .idle
        } catch let error as APIError {
            if case .unreachable = error {
                state = .unreachable
            } else {
                state = .degraded(message: error.userMessage)
            }
        } catch {
            state = .unreachable
        }
    }
}

// MARK: - Previews

extension ServerStatusModel {
    /// A model frozen in one state, for SwiftUI previews.
    static func preview(_ state: State) -> ServerStatusModel {
        let model = ServerStatusModel(health: PreviewHealth(state: state), configuration: .fallback)
        model.state = state
        return model
    }

    static let previewHealthy = HealthStatus(
        status: "ok",
        version: "0.1.0",
        environment: "local",
        database: .init(reachable: true, postgis: "3.4.2")
    )
}

/// Answers with whatever keeps the preview in the state it was asked to show.
private struct PreviewHealth: HealthChecking {
    let state: ServerStatusModel.State

    func health() async throws -> HealthStatus {
        switch state {
        case .healthy(let status):
            return status
        case .degraded(let message):
            throw APIError.server(status: 503, code: "preview", message: message, fields: [])
        case .unreachable:
            throw APIError.unreachable
        case .idle, .loading:
            throw APIError.cancelled
        }
    }
}
