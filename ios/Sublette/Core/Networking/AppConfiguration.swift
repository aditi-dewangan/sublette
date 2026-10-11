import Foundation

enum AppEnvironment: String, Equatable {
    case local
    case staging
    case production
}

/// Which server this build talks to. Set per build configuration in ios/project.yml
/// and read from Info.plist.
struct AppConfiguration: Equatable {
    let environment: AppEnvironment
    let apiBaseURL: URL

    enum Key {
        static let environment = "SubletteEnvironment"
        static let apiBaseURL = "SubletteAPIBaseURL"
    }

    /// The server on this Mac. Used when Info.plist has no usable address.
    static let fallback = AppConfiguration(
        environment: .local,
        apiBaseURL: URL(string: "http://localhost:8000")!
    )

    init(environment: AppEnvironment, apiBaseURL: URL) {
        self.environment = environment
        self.apiBaseURL = apiBaseURL
    }

    init(infoDictionary: [String: Any]?) {
        guard
            let info = infoDictionary,
            let rawURL = info[Key.apiBaseURL] as? String,
            let url = URL(string: rawURL),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty
        else {
            self = .fallback
            return
        }
        let rawEnvironment = info[Key.environment] as? String ?? ""
        self.init(
            environment: AppEnvironment(rawValue: rawEnvironment) ?? .local,
            apiBaseURL: url
        )
    }

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        AppConfiguration(infoDictionary: bundle.infoDictionary)
    }
}
