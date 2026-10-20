import Foundation
import Observation

/// A message written with no connection. It waits on the phone, survives a
/// relaunch, and goes out (in order) when the connection is back. Its id is
/// the `message_id` the server stores once, so a resend never doubles it.
struct QueuedMessage: Codable, Equatable, Identifiable {
    let id: String
    let matchID: String
    let body: String
}

@MainActor
@Observable
final class MessageOutbox {
    private(set) var queued: [QueuedMessage] = []

    /// A queued message reached the server.
    @ObservationIgnored var onSent: ((ChatMessage) -> Void)?
    /// The server refused a queued message for good (a blocked chat, say).
    @ObservationIgnored var onRefused: ((QueuedMessage, String) -> Void)?

    @ObservationIgnored private let api: ChatAPI
    @ObservationIgnored private let cache: OfflineStoring?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var flushing = false

    init(api: ChatAPI, cache: OfflineStoring?) {
        self.api = api
        self.cache = cache
    }

    /// Loads this account's waiting messages, forgetting another account's.
    func prepare(for accountID: String) {
        guard accountID != self.accountID else {
            return
        }
        self.accountID = accountID
        queued = cache?.load([QueuedMessage].self, key: CacheKey.outbox(accountID)) ?? []
    }

    func queued(for matchID: String) -> [QueuedMessage] {
        queued.filter { $0.matchID == matchID }
    }

    func add(_ message: QueuedMessage) {
        guard !queued.contains(where: { $0.id == message.id }) else {
            return
        }
        queued.append(message)
        persist()
    }

    func remove(id: String) {
        guard queued.contains(where: { $0.id == id }) else {
            return
        }
        queued.removeAll { $0.id == id }
        persist()
    }

    /// Sends what is waiting, oldest first. Stops at the first message that
    /// can't get through, so the order is kept.
    func flush() async {
        guard !flushing else {
            return
        }
        flushing = true
        defer { flushing = false }
        while let next = queued.first {
            do {
                let sent = try await api.send(matchID: next.matchID, MessageRequest(body: next.body, messageId: next.id))
                remove(id: next.id)
                onSent?(sent)
            } catch let error as APIError where error.status.map({ (400..<500).contains($0) && $0 != 429 }) == true {
                remove(id: next.id)
                onRefused?(next, error.userMessage)
            } catch {
                return // still offline, or the server is busy: try again later
            }
        }
    }

    private func persist() {
        guard let accountID else {
            return
        }
        cache?.save(queued, key: CacheKey.outbox(accountID))
    }
}
