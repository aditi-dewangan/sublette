import XCTest
@testable import Sublette

final class AppConfigurationTests: XCTestCase {
    func testReadsEnvironmentAndBaseURL() {
        let configuration = AppConfiguration(infoDictionary: [
            "SubletteEnvironment": "staging",
            "SubletteAPIBaseURL": "https://staging.example.test",
        ])

        XCTAssertEqual(configuration.environment, .staging)
        XCTAssertEqual(configuration.apiBaseURL.absoluteString, "https://staging.example.test")
    }

    func testMissingInfoFallsBackToTheLocalServer() {
        XCTAssertEqual(AppConfiguration(infoDictionary: nil), .fallback)
        XCTAssertEqual(AppConfiguration(infoDictionary: [:]), .fallback)
    }

    func testUnusableAddressFallsBackToTheLocalServer() {
        for bad in ["", "not a url", "ftp://files.example.test", "$(SUBLETTE_API_BASE_URL)", "https://"] {
            let configuration = AppConfiguration(infoDictionary: ["SubletteAPIBaseURL": bad])
            XCTAssertEqual(configuration, .fallback, "for \"\(bad)\"")
        }
    }

    func testUnknownEnvironmentNameIsTreatedAsLocal() {
        let configuration = AppConfiguration(infoDictionary: [
            "SubletteEnvironment": "prod",
            "SubletteAPIBaseURL": "https://api.example.test",
        ])

        XCTAssertEqual(configuration.environment, .local)
    }

    /// Fails if the address set in ios/project.yml never reached Info.plist.
    func testTheAppBundleCarriesTheAddressFromTheBuildSettings() throws {
        let info = Bundle(for: APIClient.self).infoDictionary
        let raw = try XCTUnwrap(info?[AppConfiguration.Key.apiBaseURL] as? String)

        XCTAssertFalse(raw.contains("$("), "The build setting was not substituted: \(raw)")
        XCTAssertEqual(AppConfiguration(infoDictionary: info).apiBaseURL.absoluteString, raw)
    }

    // MARK: - Request timeout

    func testTimeoutIsReadFromInfoPlist() {
        let configuration = AppConfiguration(infoDictionary: [
            "SubletteAPIBaseURL": "https://staging.example.test",
            "SubletteRequestTimeout": "75",
        ])

        XCTAssertEqual(configuration.requestTimeout, 75)
    }

    func testMissingOrUnusableTimeoutFallsBackToTenSeconds() {
        for bad: Any in ["", "soon", "0", "-5", "100000", "$(SUBLETTE_REQUEST_TIMEOUT)"] {
            let configuration = AppConfiguration(infoDictionary: [
                "SubletteAPIBaseURL": "https://staging.example.test",
                "SubletteRequestTimeout": bad,
            ])
            XCTAssertEqual(configuration.requestTimeout, 10, "for \(bad)")
        }
        XCTAssertEqual(AppConfiguration.fallback.requestTimeout, 10)
    }

    func testTheDebugBuildUsesTheShortTimeout() {
        let configuration = AppConfiguration.load(from: Bundle(for: APIClient.self))

        XCTAssertEqual(configuration.requestTimeout, 10)
    }

    func testTheSessionUsesTheTimeout() {
        let session = APIClient.makeSession(timeout: 75)

        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 75)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 150)
        XCTAssertFalse(session.configuration.waitsForConnectivity)
    }
}
