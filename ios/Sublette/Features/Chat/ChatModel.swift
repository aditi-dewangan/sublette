import Foundation
import Observation

/// A message on its way to the server, or one that couldn't be sent.
struct PendingMessage: Identifiable, Equatable {
    /// Also the `message_id` sent to the server, so a retry is stored once.
    let id: String
    let body: String
    var failed: Bool
    /// Written offline: kept on the phone and sent when the connection is back.
    var waiting = false
}

/// One open chat: its messages, the shared checklist and "Filled".
@MainActor
@Observable
final class ChatModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var match: Match
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: [PendingMessage] = []
    private(set) var hasOlder = false
    private(set) var state: LoadState = .idle
    /// Something that went wrong with the last action, shown above the composer.
    private(set) var problem: String?
    private(set) var safetyAcknowledged: Bool
    /// One of the two blocked the other: the chat closes.
    private(set) var isGone = false
    var draft = ""

    /// Tells the Matches list that this match changed (read, checklist, filled).
    @ObservationIgnored var onMatchChanged: ((Match) -> Void)?

    @ObservationIgnored private let api: ChatAPI
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let userID: String
    @ObservationIgnored private let makeID: () -> String
    @ObservationIgnored private let cache: OfflineStoring?
    @ObservationIgnored private let outbox: MessageOutbox?

    /// The latest messages kept on the phone for reading offline.
    static let cachedMessages = 50

    init(
        match: Match,
        api: ChatAPI,
        preferences: Preferences,
        userID: String,
        cache: OfflineStoring? = nil,
        outbox: MessageOutbox? = nil,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.match = match
        self.api = api
        self.preferences = preferences
        self.userID = userID
        self.cache = cache
        self.outbox = outbox
        self.makeID = makeID
        self.safetyAcknowledged = preferences.safetyCardSeen.contains(Self.safetyKey(userID: userID, matchID: match.id))
        self.pending = (outbox?.queued(for: match.id) ?? []).map {
            PendingMessage(id: $0.id, body: $0.body, failed: false, waiting: true)
        }
    }

    private var cacheKey: String { CacheKey.chat(userID, match: match.id) }

    var role: SwipeSide { match.role }
    var other: Person { match.other }

    /// The safety card comes before the first message you send in a chat.
    var showsSafetyCard: Bool {
        !safetyAcknowledged && !messages.contains(where: \.mine) && pending.isEmpty
    }

    /// Questions to start with, while nobody has said anything yet.
    var suggestions: [String] {
        guard messages.isEmpty, pending.isEmpty else {
            return []
        }
        switch role {
        case .renter:
            return [
                "Hi! Is the room still free for my dates?",
                "Could I see it this week, in person or on video?",
                "Has your landlord said yes to a sublet?",
                "What do utilities usually come to?",
            ]
        case .lister:
            return [
                "Hi! When would you like to see the place?",
                "Do the dates on the listing work for you?",
                "What brings you to the area?",
                "Any questions about the room or housemates?",
            ]
        }
    }

    /// The other person's "Filled" is waiting for yours.
    var awaitsMyFilled: Bool {
        match.filled.confirmed(by: role == .renter ? .lister : .renter) && !match.filled.confirmed(by: role)
    }

    func acknowledgeSafety() {
        safetyAcknowledged = true
        preferences.safetyCardSeen.insert(Self.safetyKey(userID: userID, matchID: match.id))
    }

    func load() async {
        guard state != .loading else {
            return
        }
        if messages.isEmpty {
            state = .loading
        }
        do {
            let page = try await api.messages(matchID: match.id, before: nil)
            merge(page.items)
            if messages.count <= page.items.count {
                hasOlder = page.hasMore
            }
            state = .loaded
            cache?.save(
                MessagePage(items: Array(messages.suffix(Self.cachedMessages)), hasMore: true),
                key: cacheKey
            )
            await markRead()
        } catch let error as APIError where error == .cancelled {
            state = messages.isEmpty ? .idle : .loaded
        } catch let error as APIError where error.serverCode == "chat_unavailable" {
            isGone = true
            cache?.remove(key: cacheKey)
        } catch {
            // Offline: what was loaded stays on screen, or what the phone kept.
            if messages.isEmpty, let saved = cache?.load(MessagePage.self, key: cacheKey) {
                merge(saved.items)
            }
            state = .failed(Self.message(for: error))
        }
    }

    /// Called after the student blocked the other person from this chat.
    func closeAfterBlock() {
        isGone = true
    }

    func loadOlder() async {
        guard hasOlder, let first = messages.first else {
            return
        }
        do {
            let page = try await api.messages(matchID: match.id, before: first.id)
            messages.insert(contentsOf: page.items.filter { item in !messages.contains { $0.id == item.id } }, at: 0)
            hasOlder = page.hasMore
        } catch {
            problem = Self.message(for: error)
        }
    }

    /// Sends the draft, or `text` when given (a suggested question).
    func send(_ text: String? = nil) async {
        let body = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return
        }
        if text == nil {
            draft = ""
        }
        let message = PendingMessage(id: makeID(), body: body, failed: false)
        pending.append(message)
        await deliver(message)
    }

    func retry(_ message: PendingMessage) async {
        guard let index = pending.firstIndex(where: { $0.id == message.id }) else {
            return
        }
        pending[index].failed = false
        await deliver(pending[index])
    }

    func discard(_ message: PendingMessage) {
        pending.removeAll { $0.id == message.id }
        outbox?.remove(id: message.id)
    }

    func toggle(_ step: Checklist.Step) async {
        let before = match
        let value = !match.checklist[step]
        match.checklist[step] = value
        problem = nil
        do {
            update(try await api.updateChecklist(matchID: match.id, ChecklistChange(step, value)))
        } catch {
            match = before
            problem = Self.message(for: error)
        }
    }

    func confirmFilled() async {
        problem = nil
        do {
            update(try await api.confirmFilled(matchID: match.id))
        } catch {
            problem = Self.message(for: error)
        }
    }

    /// A message sent from the outbox once the connection came back.
    func delivered(_ message: ChatMessage) {
        guard message.matchId == match.id else {
            return
        }
        merge([message])
    }

    /// The server refused a queued message for good.
    func refused(_ id: String, reason: String) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending[index].waiting = false
            pending[index].failed = true
        }
        problem = reason
    }

    /// A live event. Only this chat's are used.
    func receive(_ event: LiveEvent) {
        switch event {
        case .message(let message, let changed) where message.matchId == match.id:
            merge([message])
            update(changed)
            if !message.mine {
                Task { await markRead() }
            }
        case .match(let changed, _) where changed.id == match.id:
            update(changed)
        case .matchRemoved(let id) where id == match.id:
            isGone = true
        case .ready:
            // Back online: fetch anything missed.
            Task { await load() }
        default:
            break
        }
    }

    // MARK: - Private

    private func deliver(_ message: PendingMessage) async {
        problem = nil
        do {
            let sent = try await api.send(matchID: match.id, MessageRequest(body: message.body, messageId: message.id))
            merge([sent])
        } catch let error as APIError where error == .unreachable && outbox != nil {
            // Offline: it waits on the phone and goes out when the connection is back.
            if let index = pending.firstIndex(where: { $0.id == message.id }) {
                pending[index].waiting = true
            }
            outbox?.add(QueuedMessage(id: message.id, matchID: match.id, body: message.body))
        } catch {
            if let index = pending.firstIndex(where: { $0.id == message.id }) {
                pending[index].failed = true
            }
            problem = Self.message(for: error)
            if (error as? APIError)?.serverCode == "chat_unavailable" {
                isGone = true
            }
        }
    }

    /// Adds messages not already shown, in order, and clears the pending
    /// copies of any the phone sent.
    private func merge(_ incoming: [ChatMessage]) {
        for message in incoming where !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
        }
        let sentIDs = Set(messages.compactMap(\.messageId))
        pending.removeAll { sentIDs.contains($0.id) }
        sentIDs.forEach { outbox?.remove(id: $0) }
    }

    private func update(_ changed: Match) {
        var changed = changed
        // While the chat is open, nothing in it is unread.
        changed.unreadCount = 0
        match = changed
        onMatchChanged?(changed)
    }

    private func markRead() async {
        do {
            try await api.markRead(matchID: match.id)
            match.unreadCount = 0
            onMatchChanged?(match)
        } catch {
            // Harmless: the count is corrected the next time the chat opens.
        }
    }

    private static func message(for error: Error) -> String {
        (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
    }

    static func safetyKey(userID: String, matchID: String) -> String {
        "\(userID):\(matchID)"
    }
}
