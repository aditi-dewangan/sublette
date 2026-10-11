import XCTest
@testable import Sublette

@MainActor
final class AppStateTests: XCTestCase {
    func testStartsInRenterMode() {
        XCTAssertEqual(AppState().mode, .renter)
    }

    func testToggleFlipsBetweenTheTwoModes() {
        let state = AppState()

        state.toggleMode()
        XCTAssertEqual(state.mode, .lister)

        state.toggleMode()
        XCTAssertEqual(state.mode, .renter)
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
