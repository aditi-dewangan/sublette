import XCTest
@testable import Sublette

@MainActor
final class SessionModelTests: XCTestCase {
    func testStartsOutRestoring() {
        XCTAssertEqual(TestSession().session.state, .restoring)
    }

    func testNoSavedTokensMeansSignedOut() async {
        let test = TestSession()

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedOut)
        XCTAssertEqual(test.api.meCalls, 0, "No request is made when signed out")
    }

    func testReopeningTheAppKeepsTheStudentSignedIn() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.api.meResult = .success(Fixture.completeUser)

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedIn(Fixture.completeUser))
        XCTAssertEqual(test.session.user, Fixture.completeUser)
        XCTAssertEqual(test.preferences.cachedUser, Fixture.completeUser)
    }

    func testCompletingSignInStoresTokensAndTheUser() async {
        let test = TestSession()

        await test.session.completeSignIn(Fixture.session(user: Fixture.newUser))

        XCTAssertEqual(test.session.state, .signedIn(Fixture.newUser))
        XCTAssertEqual(test.store.load()?.accessToken, "access-1")
        XCTAssertEqual(test.store.load()?.refreshToken, "refresh-1")
        XCTAssertEqual(test.store.load()?.accessTokenExpiresAt, Fixture.now.addingTimeInterval(900))
        XCTAssertEqual(test.preferences.cachedUser, Fixture.newUser)
    }

    func testAfterSignInANewLaunchRestoresTheSameAccount() async {
        let first = TestSession()
        await first.session.completeSignIn(Fixture.session(user: Fixture.completeUser))

        // "Close the app": a new session over the same saved tokens.
        let second = TestSession(savedTokens: first.store.load())
        await second.session.restore()

        XCTAssertEqual(second.session.user, Fixture.completeUser)
    }

    // MARK: - Dependency unavailable: the server

    func testServerDownAtLaunchShowsTheSavedProfileAndStaysSignedIn() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.completeUser
        test.api.meResult = .failure(APIError.unreachable)

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedIn(Fixture.completeUser))
        XCTAssertNotNil(test.store.load(), "Being offline must never throw the tokens away")
    }

    func testServerDownAtLaunchWithNothingSavedOffersARetry() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.api.meResult = .failure(APIError.unreachable)

        await test.session.restore()

        XCTAssertEqual(test.session.state, .unreachable)
        XCTAssertNotNil(test.store.load())

        test.api.meResult = .success(Fixture.completeUser)
        await test.session.retry()

        XCTAssertEqual(test.session.state, .signedIn(Fixture.completeUser))
    }

    func testServerErrorAtLaunchIsTreatedLikeBeingOffline() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.completeUser
        test.api.meResult = .failure(Fixture.serverError(503, "service_unavailable", "Down"))

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedIn(Fixture.completeUser))
    }

    func testAStaleSavedProfileIsReplacedOnceTheServerAnswers() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.newUser
        test.api.meResult = .success(Fixture.completeUser)

        await test.session.restore()

        XCTAssertEqual(test.session.user, Fixture.completeUser)
        XCTAssertEqual(test.preferences.cachedUser, Fixture.completeUser)
    }

    // MARK: - The server ends the session

    func testWhenTheServerRefusesTheSessionAtLaunchTheAppSignsOut() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.completeUser
        test.api.meResult = .failure(Fixture.serverError(401, "token_invalid", "Please sign in again."))
        // The token manager tried to refresh, the server refused, and it threw the tokens away.
        let tokens = test.tokens
        test.api.duringMe = { await tokens.clear() }

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedOut)
        XCTAssertNil(test.store.load())
        XCTAssertNil(test.preferences.cachedUser)
    }

    func testA401OnABadConnectionDoesNotSignOut() async {
        // The access token was rejected, but the refresh could not reach the
        // server, so the tokens are still here. That is "offline", not "signed out".
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.completeUser
        test.api.meResult = .failure(Fixture.serverError(401, "token_expired", "Expired"))

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedIn(Fixture.completeUser))
        XCTAssertNotNil(test.store.load())
    }

    func testASuspendedAccountSeesWhyAndItsTokensAreGone() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.completeUser
        test.api.meResult = .failure(Fixture.serverError(403, "account_suspended", "Suspended for spam."))

        await test.session.restore()

        XCTAssertEqual(test.session.state, .suspended("Suspended for spam."))
        XCTAssertNil(test.store.load())
        XCTAssertNil(test.preferences.cachedUser)

        await test.session.signOut()
        XCTAssertEqual(test.session.state, .signedOut)
    }

    func testSessionEndedByTheServerSignsOut() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        await test.session.restore()

        await test.session.sessionEnded()

        XCTAssertEqual(test.session.state, .signedOut)
        XCTAssertNil(test.preferences.cachedUser)
    }

    // MARK: - Sign out and delete

    func testSignOutForgetsTokensAndTheSavedProfile() async {
        let test = TestSession()
        await test.session.completeSignIn(Fixture.session(user: Fixture.completeUser))

        await test.session.signOut()

        XCTAssertEqual(test.session.state, .signedOut)
        XCTAssertNil(test.store.load())
        XCTAssertNil(test.preferences.cachedUser)
        XCTAssertEqual(test.api.deleteCalls, 0, "Signing out must not delete the account")
    }

    func testDeletingTheAccountSignsTheAppOut() async throws {
        let test = TestSession()
        await test.session.completeSignIn(Fixture.session(user: Fixture.completeUser))

        try await test.session.deleteAccount()

        XCTAssertEqual(test.api.deleteCalls, 1)
        XCTAssertEqual(test.session.state, .signedOut)
        XCTAssertNil(test.store.load())
        XCTAssertNil(test.preferences.cachedUser)
    }

    func testIfDeletionFailsTheStudentStaysSignedInAndIsTold() async {
        let test = TestSession()
        await test.session.completeSignIn(Fixture.session(user: Fixture.completeUser))
        test.api.deleteResult = .failure(APIError.unreachable)

        do {
            try await test.session.deleteAccount()
            XCTFail("Expected the failure to be thrown")
        } catch {
            XCTAssertEqual(error as? APIError, .unreachable)
        }

        XCTAssertEqual(test.session.state, .signedIn(Fixture.completeUser))
        XCTAssertNotNil(test.store.load())
    }

    // MARK: - Sign-out must not be undone by requests still in the air

    func testSigningOutWhileTheProfileLoadsStaysSignedOut() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.completeUser
        test.api.meResult = .success(Fixture.completeUser)
        let session = test.session
        test.api.duringMe = { await session.signOut() }

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedOut)
        XCTAssertNil(test.store.load())
        XCTAssertNil(test.preferences.cachedUser)
    }

    func testSigningOutWhileTheProfileFailsToLoadStaysOnSignIn() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.completeUser
        test.api.meResult = .failure(APIError.unreachable)
        let session = test.session
        test.api.duringMe = { await session.signOut() }

        await test.session.restore()

        XCTAssertEqual(test.session.state, .signedOut, "Not the \"can't reach Sublette\" screen")
    }

    func testAProfileSaveThatFinishesAfterSignOutDoesNotSignBackIn() async {
        let test = TestSession()
        await test.session.completeSignIn(Fixture.session(user: Fixture.newUser))
        await test.session.signOut()

        test.session.update(Fixture.completeUser)

        XCTAssertEqual(test.session.state, .signedOut)
        XCTAssertNil(test.preferences.cachedUser)
    }

    func testAnUnfinishedSavedProfileIsNotShownBeforeTheServerAnswers() async {
        let test = TestSession(savedTokens: Fixture.tokens(expiresIn: 600))
        test.preferences.cachedUser = Fixture.newUser
        test.api.meResult = .failure(APIError.unreachable)

        await test.session.restore()

        // Offline with an unfinished profile: offer a retry, not a stale form.
        XCTAssertEqual(test.session.state, .unreachable)
    }

    func testUpdatingTheProfileUpdatesTheSavedCopy() async {
        let test = TestSession()
        await test.session.completeSignIn(Fixture.session(user: Fixture.newUser))

        test.session.update(Fixture.completeUser)

        XCTAssertEqual(test.session.user, Fixture.completeUser)
        XCTAssertEqual(test.preferences.cachedUser, Fixture.completeUser)
    }
}
