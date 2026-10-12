import UIKit
import XCTest
@testable import Sublette

final class PreferencesTests: XCTestCase {
    func testDefaults() {
        let preferences = Preferences.ephemeral()

        XCTAssertEqual(preferences.lastMode, .renter)
        XCTAssertFalse(preferences.hasLaunchedBefore)
        XCTAssertNil(preferences.cachedUser)
        XCTAssertEqual(preferences.usersWhoChoseAMode, [])
    }

    func testValuesAreKept() {
        let preferences = Preferences.ephemeral()

        preferences.lastMode = .lister
        preferences.cachedUser = Fixture.completeUser
        preferences.usersWhoChoseAMode = ["user-1", "user-2"]

        XCTAssertEqual(preferences.lastMode, .lister)
        XCTAssertEqual(preferences.cachedUser, Fixture.completeUser)
        XCTAssertEqual(preferences.usersWhoChoseAMode, ["user-1", "user-2"])

        preferences.cachedUser = nil
        XCTAssertNil(preferences.cachedUser)
    }

    func testTwoEphemeralPreferencesDoNotShareAnything() {
        let first = Preferences.ephemeral()
        first.lastMode = .lister

        XCTAssertEqual(Preferences.ephemeral().lastMode, .renter)
    }

    func testAFreshInstallThrowsAwayTokensLeftInTheKeychain() {
        let preferences = Preferences.ephemeral()
        let store = InMemoryTokenStore(Fixture.tokens(expiresIn: 600))

        FirstLaunch.clearStaleTokensIfNeeded(preferences: preferences, store: store)

        XCTAssertNil(store.load())
        XCTAssertTrue(preferences.hasLaunchedBefore)
    }

    func testLaterLaunchesKeepTheTokens() {
        let preferences = Preferences.ephemeral()
        preferences.hasLaunchedBefore = true
        let store = InMemoryTokenStore(Fixture.tokens(expiresIn: 600))

        FirstLaunch.clearStaleTokensIfNeeded(preferences: preferences, store: store)

        XCTAssertNotNil(store.load())
    }
}

/// Uses the simulator's real Keychain, under a service name of its own.
final class KeychainTokenStoreTests: XCTestCase {
    private let store = KeychainTokenStore(service: "app.sublette.tests", account: "tokens")

    override func setUp() {
        super.setUp()
        store.clear()
    }

    override func tearDown() {
        store.clear()
        super.tearDown()
    }

    func testEmptyAtFirst() {
        XCTAssertNil(store.load())
    }

    func testTokensSurviveBeingReadByANewStore() {
        let tokens = Fixture.tokens(expiresIn: 600)
        store.save(tokens)

        // A second store over the same Keychain entry stands in for a relaunch.
        let afterRelaunch = KeychainTokenStore(service: "app.sublette.tests", account: "tokens")

        XCTAssertEqual(afterRelaunch.load(), tokens)
    }

    func testSavingAgainReplacesTheTokens() {
        store.save(Fixture.tokens(expiresIn: 600, access: "old"))
        store.save(Fixture.tokens(expiresIn: 600, access: "new"))

        XCTAssertEqual(store.load()?.accessToken, "new")
    }

    func testClearRemovesThem() {
        store.save(Fixture.tokens(expiresIn: 600))
        store.clear()

        XCTAssertNil(store.load())
    }

    func testStoresWithDifferentNamesAreSeparate() {
        store.save(Fixture.tokens(expiresIn: 600))
        let other = KeychainTokenStore(service: "app.sublette.tests.other", account: "tokens")
        defer { other.clear() }

        XCTAssertNil(other.load())
    }
}

final class ImageResizerTests: XCTestCase {
    private func image(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testALargePhotoIsShrunkToFit() throws {
        let jpeg = try XCTUnwrap(ImageResizer.jpegData(from: image(width: 4000, height: 2000)))
        let result = try XCTUnwrap(UIImage(data: jpeg))

        XCTAssertEqual(result.size.width * result.scale, 1600)
        XCTAssertEqual(result.size.height * result.scale, 800)
        // JPEG files start with FF D8.
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
    }

    func testASmallPhotoIsNotEnlarged() throws {
        let jpeg = try XCTUnwrap(ImageResizer.jpegData(from: image(width: 300, height: 200)))
        let result = try XCTUnwrap(UIImage(data: jpeg))

        XCTAssertEqual(result.size.width * result.scale, 300)
        XCTAssertEqual(result.size.height * result.scale, 200)
    }

    func testSomethingThatIsNotAnImageIsRefused() {
        XCTAssertNil(ImageResizer.jpegData(from: Data("not an image".utf8)))
        XCTAssertNil(ImageResizer.jpegData(from: Data()))
    }
}
