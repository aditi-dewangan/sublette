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
}
