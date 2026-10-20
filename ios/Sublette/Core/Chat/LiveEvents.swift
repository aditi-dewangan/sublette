import Foundation
import Observation

/// The live connection: a WebSocket to `/v1/ws` while the app is open and
/// signed in. New messages, matches and checklist changes arrive here within
/// a second; when the app is closed they come as push notifications instead.
///
/// The connection looks after itself: it reconnects after a drop (waiting a
/// little longer each time, up to 30 seconds), refreshes the token when the
/// server closes with 4401, and gives up only when the account is suspended
/// (4403). Each time it connects it reports `.ready`, so screens can reload
/// anything they missed.
@MainActor
@Observable
final class LiveEvents {
    private(set) var isConnected = false

    /// Called on the main actor for every event.
    @ObservationIgnored var onEvent: ((LiveEvent) -> Void)?
    /// Called when the server closes the connection because the account was suspended.
    @ObservationIgnored var onSuspended: (() -> Void)?

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let tokens: AccessTokenProviding
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// Which run of the loop is current. A loop that was stopped can finish
    /// late; it must not clear the state of the run that replaced it.
    @ObservationIgnored private var generation = 0

    private enum Ending {
        case tokenRejected
        case suspended
        case dropped(afterReady: Bool)
    }

    nonisolated static let maxWait: TimeInterval = 30

    init(client: APIClient, tokens: AccessTokenProviding, session: URLSession = URLSession(configuration: .default)) {
        self.url = client.webSocketURL(for: .liveEvents)
        self.tokens = tokens
        self.session = session
    }

    /// Connects, unless already connected or connecting.
    func start() {
        guard loop == nil, url != nil else {
            return
        }
        generation += 1
        let run = generation
        loop = Task { [weak self] in
            await self?.run(run)
        }
    }

    /// Disconnects, as when the app goes to the background or signs out.
    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
    }

    /// How long to wait before the next try, after `failures` drops in a row.
    nonisolated static func wait(afterFailures failures: Int) -> TimeInterval {
        min(maxWait, pow(2, Double(max(0, failures - 1))))
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == generation && !Task.isCancelled
    }

    /// Ends this run, clearing the loop only if no newer run replaced it.
    private func finish(_ run: Int) {
        if run == generation {
            loop = nil
        }
    }

    private func run(_ run: Int) async {
        var failures = 0
        while isCurrent(run) {
            guard let token = await tokens.accessToken() else {
                break // signed out
            }
            switch await connectOnce(token: token, run: run) {
            case .suspended:
                finish(run)
                if run == generation {
                    onSuspended?()
                }
                return
            case .tokenRejected:
                failures += 1
                if await tokens.refreshedAccessToken(afterRejecting: token) == nil, failures > 3 {
                    finish(run)
                    return
                }
            case .dropped(let afterReady):
                failures = afterReady ? 1 : failures + 1
            }
            guard isCurrent(run) else {
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.wait(afterFailures: failures) * 1_000_000_000))
        }
        finish(run)
    }

    private func connectOnce(token: String, run: Int) async -> Ending {
        guard let url else {
            return .suspended
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        defer {
            if run == generation {
                isConnected = false
                self.socket = nil
            } else {
                socket.cancel(with: .goingAway, reason: nil)
            }
        }

        let decoder = APIClient.makeDecoder()
        var ready = false
        do {
            while isCurrent(run) {
                let data: Data
                switch try await socket.receive() {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                // An event this version can't read is skipped, not fatal.
                guard let event = try? decoder.decode(LiveEvent.self, from: data) else {
                    continue
                }
                guard run == generation else {
                    break // stopped while waiting; a newer run delivers events now
                }
                if event == .ready {
                    ready = true
                    isConnected = true
                }
                onEvent?(event)
            }
        } catch {
            // Closed by the server, or the network went away.
        }
        switch socket.closeCode.rawValue {
        case 4401: return .tokenRejected
        case 4403: return .suspended
        default: return .dropped(afterReady: ready)
        }
    }
}
