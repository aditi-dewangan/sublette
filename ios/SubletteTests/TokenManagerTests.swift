import XCTest
@testable import Sublette

final class TokenManagerTests: XCTestCase {
    private func makeManager(
        saved: AuthTokens?,
        refresher: StubRefresher = StubRefresher()
    ) -> (TokenManager, InMemoryTokenStore, StubRefresher) {
        let store = InMemoryTokenStore(saved)
        let manager = TokenManager(store: store, refresher: refresher, now: { Fixture.now })
        return (manager, store, refresher)
    }

    func testSignedOutHasNoToken() async {
        let (manager, _, refresher) = makeManager(saved: nil)

        let token = await manager.accessToken()
        let hasTokens = await manager.hasTokens

        XCTAssertNil(token)
        XCTAssertFalse(hasTokens)
        XCTAssertEqual(refresher.calls, [])
    }

    func testTokensSavedByAnEarlierLaunchAreLoaded() async {
        let (manager, _, refresher) = makeManager(saved: Fixture.tokens(expiresIn: 600))

        let token = await manager.accessToken()

        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(refresher.calls, [], "A fresh token must not be refreshed")
    }

    func testATokenAboutToExpireIsRefreshedFirst() async {
        let (manager, store, refresher) = makeManager(saved: Fixture.tokens(expiresIn: 30))

        let token = await manager.accessToken()

        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(refresher.calls, ["refresh-1"])
        XCTAssertEqual(store.load()?.accessToken, "access-2")
        XCTAssertEqual(store.load()?.refreshToken, "refresh-2")
        XCTAssertEqual(store.load()?.accessTokenExpiresAt, Fixture.now.addingTimeInterval(900))
    }

    func testAnExpiredTokenIsRefreshedFirst() async {
        let (manager, _, refresher) = makeManager(saved: Fixture.tokens(expiresIn: -3600))

        let token = await manager.accessToken()

        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(refresher.calls.count, 1)
    }

    func testManyRequestsAtOnceShareOneRefresh() async {
        let refresher = StubRefresher()
        refresher.delayNanoseconds = 50_000_000
        let (manager, _, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)

        async let first = manager.accessToken()
        async let second = manager.accessToken()
        async let third = manager.accessToken()
        let tokens = await [first, second, third]

        XCTAssertEqual(tokens, ["access-2", "access-2", "access-2"])
        XCTAssertEqual(refresher.calls.count, 1)
    }

    // MARK: - The server ends the session

    func testRefreshRefusedSignsOut() async {
        let refresher = StubRefresher(.failure(Fixture.serverError(401, "token_expired", "Expired")))
        let (manager, store, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)
        let ended = expectation(description: "the app is told the session ended")
        await manager.setSessionEndedHandler { ended.fulfill() }

        let token = await manager.accessToken()

        await fulfillment(of: [ended], timeout: 1)
        XCTAssertNil(token)
        XCTAssertNil(store.load())
        let hasTokens = await manager.hasTokens
        XCTAssertFalse(hasTokens)
    }

    func testSuspendedAccountSignsOut() async {
        let refresher = StubRefresher(.failure(Fixture.serverError(403, "account_suspended", "Suspended")))
        let (manager, store, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)

        _ = await manager.accessToken()

        XCTAssertNil(store.load())
    }

    // MARK: - Dependency unavailable: the server

    func testServerUnreachableDuringRefreshKeepsTheStudentSignedIn() async {
        let refresher = StubRefresher(.failure(APIError.unreachable))
        let (manager, store, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)
        let sessionEnded = Flag()
        await manager.setSessionEndedHandler { sessionEnded.set() }

        let token = await manager.accessToken()

        // The old token is sent; the request will fail by itself. Nothing is thrown away.
        XCTAssertEqual(token, "access-1")
        XCTAssertEqual(store.load(), Fixture.tokens(expiresIn: -1))
        XCTAssertFalse(sessionEnded.isSet)
    }

    func testServerErrorDuringRefreshKeepsTheStudentSignedIn() async {
        let refresher = StubRefresher(.failure(Fixture.serverError(503, "service_unavailable", "Down")))
        let (manager, store, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)

        _ = await manager.accessToken()

        XCTAssertNotNil(store.load())
    }

    func testRefreshWorksAgainOnceTheServerIsBack() async {
        let refresher = StubRefresher(.failure(APIError.unreachable))
        let (manager, _, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)
        _ = await manager.accessToken()

        refresher.result = .success(
            TokenResponse(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 900)
        )
        let token = await manager.accessToken()

        XCTAssertEqual(token, "access-2")
    }

    // MARK: - Sign-out must not be undone by a refresh still in the air

    func testSigningOutDuringARefreshDoesNotBringTheTokensBack() async {
        let refresher = StubRefresher()
        refresher.delayNanoseconds = 300_000_000
        let (manager, store, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)

        async let pending = manager.accessToken()
        try? await Task.sleep(nanoseconds: 60_000_000)  // the refresh is now in the air
        await manager.clear()
        let token = await pending

        XCTAssertEqual(refresher.calls, ["refresh-1"])
        XCTAssertNil(token)
        XCTAssertNil(store.load(), "The answer to an abandoned refresh must be thrown away")
        let hasTokens = await manager.hasTokens
        XCTAssertFalse(hasTokens)
    }

    func testALateRefusalForAnOldSessionDoesNotEndTheNewOne() async {
        let refresher = StubRefresher(.failure(Fixture.serverError(401, "token_expired", "Expired")))
        refresher.delayNanoseconds = 300_000_000
        let (manager, store, _) = makeManager(saved: Fixture.tokens(expiresIn: -1), refresher: refresher)
        let sessionEnded = Flag()
        await manager.setSessionEndedHandler { sessionEnded.set() }
        let newSession = AuthTokens(
            accessToken: "access-new",
            refreshToken: "refresh-new",
            accessTokenExpiresAt: Fixture.now.addingTimeInterval(900)
        )

        async let pending = manager.accessToken()
        try? await Task.sleep(nanoseconds: 60_000_000)
        await manager.setTokens(newSession)  // signed in again meanwhile
        _ = await pending

        XCTAssertEqual(store.load(), newSession)
        XCTAssertFalse(sessionEnded.isSet)
    }

    func testPrepareReadsTheKeychainAgainAndClearsAFreshInstall() async {
        let store = InMemoryTokenStore()
        let manager = TokenManager(store: store, refresher: StubRefresher(), now: { Fixture.now })
        // Tokens that became readable only after the manager was created.
        store.save(Fixture.tokens(expiresIn: 600))

        let laterLaunch = Preferences.ephemeral()
        laterLaunch.hasLaunchedBefore = true
        await manager.prepare(preferences: laterLaunch)
        let loaded = await manager.accessToken()
        XCTAssertEqual(loaded, "access-1")

        // A fresh install: whatever the Keychain kept from before is thrown away.
        await manager.prepare(preferences: Preferences.ephemeral())
        let afterReinstall = await manager.accessToken()
        XCTAssertNil(afterReinstall)
        XCTAssertNil(store.load())
    }

    // MARK: - A 401 on an ordinary request

    func testRejectedTokenIsRefreshed() async {
        let (manager, _, refresher) = makeManager(saved: Fixture.tokens(expiresIn: 600))

        let token = await manager.refreshedAccessToken(afterRejecting: "access-1")

        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(refresher.calls, ["refresh-1"])
    }

    func testRejectedOldTokenGetsTheNewerOneWithoutAnotherRefresh() async {
        let (manager, _, refresher) = makeManager(saved: Fixture.tokens(expiresIn: 600, access: "access-9"))

        let token = await manager.refreshedAccessToken(afterRejecting: "access-1")

        XCTAssertEqual(token, "access-9")
        XCTAssertEqual(refresher.calls, [])
    }

    func testSetAndClear() async {
        let (manager, store, _) = makeManager(saved: nil)

        await manager.setTokens(Fixture.tokens(expiresIn: 600))
        XCTAssertEqual(store.load()?.accessToken, "access-1")

        await manager.clear()
        XCTAssertNil(store.load())
        let token = await manager.accessToken()
        XCTAssertNil(token)
    }
}
