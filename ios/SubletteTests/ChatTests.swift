import UserNotifications
import XCTest
@testable import Sublette

/// One chat: sending, live messages, the safety card, the checklist and "Filled".
@MainActor
final class ChatModelTests: XCTestCase {
    private var ids = 0

    private func makeChat(
        _ api: StubChatAPI = StubChatAPI(),
        match: Match = Fixture.match(),
        preferences: Preferences = .ephemeral()
    ) -> ChatModel {
        ChatModel(match: match, api: api, preferences: preferences, userID: "user-1") { [unowned self] in
            ids += 1
            return "local-\(ids)"
        }
    }

    func testLoadingShowsMessagesAndMarksThemRead() async {
        let api = StubChatAPI()
        api.pages = [.success(MessagePage(items: [Fixture.message(id: "a"), Fixture.message(id: "b")], hasMore: true))]
        let chat = makeChat(api)

        await chat.load()

        XCTAssertEqual(chat.messages.map(\.id), ["a", "b"])
        XCTAssertTrue(chat.hasOlder)
        XCTAssertEqual(api.readCalls, ["match-1"])
    }

    func testOlderMessagesGoAboveTheFirstOne() async {
        let api = StubChatAPI()
        api.pages = [
            .success(MessagePage(items: [Fixture.message(id: "c")], hasMore: true)),
            .success(MessagePage(items: [Fixture.message(id: "a"), Fixture.message(id: "b")], hasMore: false)),
        ]
        let chat = makeChat(api)
        await chat.load()

        await chat.loadOlder()

        XCTAssertEqual(api.pageRequests, [nil, "c"])
        XCTAssertEqual(chat.messages.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(chat.hasOlder)
    }

    func testSendingClearsTheDraftAndShowsTheMessageOnce() async {
        let api = StubChatAPI()
        let chat = makeChat(api)
        chat.draft = "  Is it still free?  "

        await chat.send()

        XCTAssertEqual(chat.draft, "")
        XCTAssertEqual(api.sent, [MessageRequest(body: "Is it still free?", messageId: "local-1")])
        XCTAssertEqual(chat.messages.map(\.body), ["Is it still free?"])
        XCTAssertTrue(chat.pending.isEmpty)

        // The same message also comes back over the live connection.
        let echo = Fixture.message(id: "server-local-1", body: "Is it still free?", mine: true, messageID: "local-1")
        chat.receive(.message(echo, Fixture.match()))
        XCTAssertEqual(chat.messages.count, 1)
    }

    func testABlankDraftIsNotSent() async {
        let api = StubChatAPI()
        let chat = makeChat(api)
        chat.draft = "   "

        await chat.send()

        XCTAssertTrue(api.sent.isEmpty)
    }

    func testAFailedMessageIsRetriedWithTheSameID() async {
        let api = StubChatAPI()
        api.sendResults = [.failure(APIError.unreachable)]
        let chat = makeChat(api)

        await chat.send("hello")
        XCTAssertEqual(chat.pending.map(\.failed), [true])
        XCTAssertNotNil(chat.problem)

        await chat.retry(chat.pending[0])

        XCTAssertEqual(api.sent.map(\.messageId), ["local-1", "local-1"], "a retry must never make a second copy")
        XCTAssertTrue(chat.pending.isEmpty)
        XCTAssertEqual(chat.messages.map(\.body), ["hello"])
    }

    func testOnlyThisChatsLiveMessagesAreShownAndTheyAreRead() async {
        let api = StubChatAPI()
        let chat = makeChat(api)
        var updates: [Match] = []
        chat.onMatchChanged = { updates.append($0) }

        chat.receive(.message(Fixture.message(id: "x", matchID: "other"), Fixture.match(id: "other")))
        var changed = Fixture.match()
        changed.unreadCount = 1
        chat.receive(.message(Fixture.message(id: "a"), changed))
        chat.receive(.message(Fixture.message(id: "a"), changed))

        XCTAssertEqual(chat.messages.map(\.id), ["a"])
        XCTAssertEqual(updates.last?.unreadCount, 0, "an open chat has nothing unread")
    }

    func testTheSafetyCardComesFirstAndIsRememberedPerChat() {
        let preferences = Preferences.ephemeral()
        let chat = makeChat(preferences: preferences)
        XCTAssertTrue(chat.showsSafetyCard)

        chat.acknowledgeSafety()

        XCTAssertFalse(chat.showsSafetyCard)
        XCTAssertFalse(makeChat(preferences: preferences).showsSafetyCard, "remembered after closing the chat")
        XCTAssertTrue(makeChat(match: Fixture.match(id: "match-2"), preferences: preferences).showsSafetyCard)
    }

    func testNoSafetyCardOnceYouHaveWritten() async {
        let api = StubChatAPI()
        api.pages = [.success(MessagePage(items: [Fixture.message(id: "a", mine: true)], hasMore: false))]
        let chat = makeChat(api)

        await chat.load()

        XCTAssertFalse(chat.showsSafetyCard)
    }

    func testSuggestionsFitEachSideAndGoAwayOnceTalking() async {
        let lister = makeChat()
        var renterMatch = Fixture.match()
        renterMatch = Match(
            id: renterMatch.id, role: .renter, listing: renterMatch.listing, renter: renterMatch.renter,
            lister: renterMatch.lister, createdAt: renterMatch.createdAt
        )
        let renter = makeChat(match: renterMatch)

        XCTAssertNotEqual(lister.suggestions, renter.suggestions)
        XCTAssertEqual(renter.suggestions.count, 4)

        await renter.send(renter.suggestions[0])
        XCTAssertEqual(renter.suggestions, [])
    }

    func testTickingTheChecklistShowsAtOnceAndUndoesOnFailure() async {
        let api = StubChatAPI()
        let chat = makeChat(api)

        await chat.toggle(.tourDone)
        XCTAssertTrue(chat.match.checklist.tourDone)
        XCTAssertEqual(api.checklistChanges, [ChecklistChange(.tourDone, true)])

        api.checklistResult = .failure(APIError.unreachable)
        await chat.toggle(.tourDone)
        XCTAssertTrue(chat.match.checklist.tourDone, "put back when the server can't be reached")
        XCTAssertNotNil(chat.problem)
    }

    func testTheOtherSidesFilledWaitsForYours() async {
        var match = Fixture.match()
        match = Match(
            id: match.id, role: .renter, listing: match.listing, renter: match.renter,
            lister: match.lister, createdAt: match.createdAt,
            filled: Filled(renterConfirmed: false, listerConfirmed: true, completed: false)
        )
        let chat = makeChat(match: match)

        XCTAssertTrue(chat.awaitsMyFilled)
    }
}

/// The Matches list kept current by live events.
@MainActor
final class MatchesLiveTests: XCTestCase {
    private func makeModel(_ deck: StubDeckAPI = StubDeckAPI(), chat: StubChatAPI = StubChatAPI()) -> MatchesModel {
        let model = MatchesModel(api: deck, chatAPI: chat, preferences: .ephemeral())
        model.prepare(for: "user-1")
        return model
    }

    func testANewMessageMovesItsChatToTheTopWithItsUnreadCount() async {
        let deck = StubDeckAPI()
        deck.matchesResult = .success(MatchPage(items: [Fixture.match(id: "a"), Fixture.match(id: "b")]))
        let model = makeModel(deck)
        await model.load()

        var changed = Fixture.match(id: "b")
        changed.unreadCount = 2
        model.handle(.message(Fixture.message(id: "m", matchID: "b"), changed))

        XCTAssertEqual(model.matches.map(\.id), ["b", "a"])
        XCTAssertEqual(model.unreadCount(as: .lister), 2)
        XCTAssertEqual(model.unreadCount(as: .renter), 0)
    }

    func testAMatchFromANotificationIsFetchedIfNotLoaded() async {
        let model = makeModel()

        let found = await model.match(id: "fetched")

        XCTAssertEqual(found?.id, "fetched")
        XCTAssertEqual(model.matches.map(\.id), ["fetched"])
    }

    func testTheOpenChatGetsItsEventsAndReadingClearsTheBadge() async {
        let deck = StubDeckAPI()
        var unread = Fixture.match(id: "a")
        unread.unreadCount = 3
        deck.matchesResult = .success(MatchPage(items: [unread]))
        let model = makeModel(deck)
        await model.load()

        let chat = model.openChat(unread)
        await chat.load()
        model.handle(.message(Fixture.message(id: "m", matchID: "a"), unread))

        XCTAssertEqual(chat.messages.map(\.id), ["m"])
        XCTAssertEqual(model.unreadCount(as: .lister), 0)
        XCTAssertTrue(model.openChat(unread) === chat, "the same chat, not a fresh copy")
    }

    func testSwitchingAccountsForgetsTheOpenChat() {
        let model = makeModel()
        _ = model.openChat(Fixture.match())

        model.prepare(for: "user-2")

        XCTAssertNil(model.activeChat)
    }
}

/// Permission at the first match, the token, and tapping a notification.
@MainActor
final class NotificationsTests: XCTestCase {
    func testSigningInNeverAsksForPermission() async {
        let permissions = StubPermissions(.notDetermined)
        let model = NotificationsModel(api: StubChatAPI(), permissions: permissions, preferences: .ephemeral())

        await model.didSignIn()

        XCTAssertEqual(permissions.requests, 0)
        XCTAssertEqual(permissions.registrations, 0)
    }

    func testTheFirstMatchAsksOnceAndRegisters() async {
        let permissions = StubPermissions(.notDetermined)
        let model = NotificationsModel(api: StubChatAPI(), permissions: permissions, preferences: .ephemeral())

        await model.askAtFirstMatch()
        await model.askAtFirstMatch()

        XCTAssertEqual(permissions.requests, 1)
        XCTAssertEqual(permissions.registrations, 1)
    }

    func testAnAllowedPhoneRegistersAtSignInAndWithdrawsAtSignOut() async {
        let api = StubChatAPI()
        let permissions = StubPermissions(.authorized)
        let model = NotificationsModel(api: api, permissions: permissions, preferences: .ephemeral())

        await model.didSignIn()
        await model.didRegister(deviceToken: Data([0x0a, 0xff, 0x01]))
        await model.willSignOut()

        XCTAssertEqual(permissions.registrations, 1)
        XCTAssertEqual(api.registered, [DeviceRequest(token: "0aff01", environment: .current)])
        XCTAssertEqual(api.unregistered, ["0aff01"])
    }

    func testATokenAfterSignOutIsNotSent() async {
        let api = StubChatAPI()
        let model = NotificationsModel(api: api, permissions: StubPermissions(.authorized), preferences: .ephemeral())

        await model.didRegister(deviceToken: Data([1]))

        XCTAssertTrue(api.registered.isEmpty)
    }

    func testTappingANotificationNamesWhatToOpen() {
        let model = NotificationsModel(api: StubChatAPI(), permissions: StubPermissions(.authorized), preferences: .ephemeral())

        model.didTap(userInfo: ["kind": "message", "match_id": "m1", "role": "lister", "aps": [:]])
        XCTAssertEqual(model.target, .chat(matchID: "m1", role: .lister))

        model.didTap(userInfo: ["kind": "listing", "listing_id": "l1"])
        XCTAssertEqual(model.target, .deck)

        XCTAssertNil(NotificationTarget(userInfo: ["kind": "message"]), "no match id: nothing to open")
        XCTAssertNil(NotificationTarget(userInfo: ["kind": "something new"]))
    }

    func testNoBannerForTheChatOnScreen() {
        let model = NotificationsModel(api: StubChatAPI(), permissions: StubPermissions(.authorized), preferences: .ephemeral())
        let push: [AnyHashable: Any] = ["kind": "message", "match_id": "m1", "role": "renter"]

        XCTAssertFalse(model.showsBanner(userInfo: push, openChatID: "m1"))
        XCTAssertTrue(model.showsBanner(userInfo: push, openChatID: "m2"))
        XCTAssertTrue(model.showsBanner(userInfo: push, openChatID: nil))
    }

    func testOpeningAChatSwitchesToItsSideAndTab() {
        let state = AppState(preferences: .ephemeral(), mode: .renter)

        state.openChat(matchID: "m1", role: .lister)

        XCTAssertEqual(state.mode, .lister)
        XCTAssertEqual(state.tab, .matches)
        XCTAssertEqual(state.chatToOpen, "m1")
        state.chatOpened()
        XCTAssertNil(state.chatToOpen)
    }

    func testSwitchingModeStartsOnThatModesFirstTab() {
        let state = AppState(preferences: .ephemeral(), mode: .renter)
        state.tab = .map

        state.toggleMode()

        XCTAssertEqual(state.tab, .listings)
    }
}

/// The live connection's waiting and its events, from real server samples.
final class LiveEventTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testWaitsLongerAfterEachDropUpToThirtySeconds() {
        XCTAssertEqual(LiveEvents.wait(afterFailures: 1), 1)
        XCTAssertEqual(LiveEvents.wait(afterFailures: 3), 4)
        XCTAssertEqual(LiveEvents.wait(afterFailures: 20), 30)
    }

    func testTheServersEventsDecode() throws {
        XCTAssertEqual(try decoder.decode(LiveEvent.self, from: Fixture.sample("ws_ready")), .ready)

        guard case .match(let match, let isNew) = try decoder.decode(LiveEvent.self, from: Fixture.sample("ws_match_event")) else {
            return XCTFail("not a match event")
        }
        XCTAssertTrue(isNew)
        XCTAssertEqual(match.role, .renter)
        XCTAssertNotNil(match.listing.address, "a matched renter sees the address")

        guard case .message(let message, let changed) = try decoder.decode(LiveEvent.self, from: Fixture.sample("ws_message_event")) else {
            return XCTFail("not a message event")
        }
        XCTAssertFalse(message.mine)
        XCTAssertEqual(changed.unreadCount, 1)
        XCTAssertEqual(changed.lastMessage, message)
    }

    func testAnEventFromANewerServerIsSkipped() throws {
        let event = try decoder.decode(LiveEvent.self, from: Data(#"{"type": "typing"}"#.utf8))

        XCTAssertEqual(event, .unknown)
    }

    func testTheWebSocketAddressFollowsTheServers() {
        let local = APIClient(baseURL: URL(string: "http://localhost:8000")!)
        let hosted = APIClient(baseURL: URL(string: "https://api.example.test/")!)

        XCTAssertEqual(local.webSocketURL(for: .liveEvents)?.absoluteString, "ws://localhost:8000/v1/ws")
        XCTAssertEqual(hosted.webSocketURL(for: .liveEvents)?.absoluteString, "wss://api.example.test/v1/ws")
    }
}

/// The chat responses in docs/contract/samples.
final class ChatContractTests: XCTestCase {
    private let decoder = APIClient.makeDecoder()

    func testChatSamples() throws {
        let message = try decoder.decode(ChatMessage.self, from: Fixture.sample("message"))
        XCTAssertTrue(message.mine)
        XCTAssertNotNil(message.messageId)

        let page = try decoder.decode(MessagePage.self, from: Fixture.sample("messages"))
        XCTAssertEqual(page.items.map(\.mine), [false, true])
        XCTAssertFalse(page.hasMore)

        let match = try decoder.decode(Match.self, from: Fixture.sample("match"))
        XCTAssertTrue(match.checklist.tourDone)
        XCTAssertEqual(match.lastMessage?.body, "Yes, 5pm works.")

        let filled = try decoder.decode(Match.self, from: Fixture.sample("match_filled"))
        XCTAssertTrue(filled.filled.listerConfirmed)
        XCTAssertEqual(filled.listing.status, .filled)

        let error = try decoder.decode(APIErrorBody.self, from: Fixture.sample("error_not_your_match"))
        XCTAssertEqual(error.code, "not_your_match")

        let user = try decoder.decode(User.self, from: Fixture.sample("user_complete"))
        XCTAssertEqual(user.completedSublets, 0)
    }

    func testRequestsUseTheServersFieldNames() throws {
        let encoder = APIClient.makeEncoder()
        func json<T: Encodable>(_ value: T) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? NSDictionary)
        }

        XCTAssertEqual(try json(MessageRequest(body: "hi", messageId: "m1")), ["body": "hi", "message_id": "m1"])
        XCTAssertEqual(try json(ChecklistChange(.landlordConsentConfirmed, true)), ["landlord_consent_confirmed": true])
        XCTAssertEqual(try json(DeviceRequest(token: "ab", environment: .sandbox)), ["token": "ab", "environment": "sandbox"])
    }

    func testTheEndpointsMatchTheContract() {
        XCTAssertEqual(Endpoint.messages(matchID: "m", before: "x").query, [URLQueryItem(name: "before", value: "x")])
        XCTAssertEqual(Endpoint.checklist(matchID: "m").method, .patch)
        XCTAssertEqual(Endpoint.unregisterDevice(token: "t").path, "/v1/devices/t")
    }
}

/// In the simulator the phone's own id stands in for Apple's token.
@MainActor
final class SimulatorPushTests: XCTestCase {
    func testASimulatorRegistersItsOwnID() async {
        let api = StubChatAPI()
        let permissions = StubPermissions(.authorized)
        let model = NotificationsModel(
            api: api, permissions: permissions, preferences: .ephemeral(),
            simulatorID: "E4D956D3-B961-4689-854F-5B74239D2F8D"
        )

        await model.didSignIn()

        XCTAssertEqual(api.registered, [DeviceRequest(token: "e4d956d3b9614689854f5b74239d2f8d", environment: .simulator)])
        XCTAssertEqual(permissions.registrations, 0, "Apple isn't asked for a token")
    }
}
