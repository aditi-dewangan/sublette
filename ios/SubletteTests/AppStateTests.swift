import XCTest
@testable import Sublette

@MainActor
final class AppStateTests: XCTestCase {
    func testStartsInRenterMode() {
        XCTAssertEqual(AppState(preferences: .ephemeral()).mode, .renter)
    }

    func testToggleFlipsBetweenTheTwoModes() {
        let state = AppState(preferences: .ephemeral())

        state.toggleMode()
        XCTAssertEqual(state.mode, .lister)

        state.toggleMode()
        XCTAssertEqual(state.mode, .renter)
    }

    func testTheLastModeUsedIsRemembered() {
        let preferences = Preferences.ephemeral()
        AppState(preferences: preferences).setMode(.lister)

        // "Reopen the app."
        XCTAssertEqual(AppState(preferences: preferences).mode, .lister)
    }

    func testChoosingAStartingModeIsRememberedPerAccount() {
        let preferences = Preferences.ephemeral()
        let state = AppState(preferences: preferences)
        XCTAssertFalse(state.hasChosenStartingMode(userID: "user-1"))

        state.chooseStartingMode(.lister, userID: "user-1")

        XCTAssertEqual(state.mode, .lister)
        XCTAssertTrue(state.hasChosenStartingMode(userID: "user-1"))
        XCTAssertFalse(state.hasChosenStartingMode(userID: "user-2"))

        let reopened = AppState(preferences: preferences)
        XCTAssertTrue(reopened.hasChosenStartingMode(userID: "user-1"))
        XCTAssertEqual(reopened.mode, .lister)
    }

    func testThereAreExactlyTwoModes() {
        XCTAssertEqual(AppMode.allCases, [.renter, .lister])
    }

    func testRenterModeIsYellowAndListerModeIsOrange() {
        XCTAssertEqual(AppMode.renter.accent, Brand.yellow)
        XCTAssertEqual(AppMode.lister.accent, Brand.orange)
    }

    func testTextOnBothAccentsIsInkNeverWhite() {
        for mode in AppMode.allCases {
            XCTAssertEqual(mode.textOnAccent, Brand.ink)
        }
    }
}
