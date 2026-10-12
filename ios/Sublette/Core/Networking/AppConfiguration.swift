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
    /// Seconds a request waits before "can't reach the server". Longer on
    /// staging, where a free server that went to sleep takes about a minute to wake.
    let requestTimeout: TimeInterval

    static let defaultRequestTimeout: TimeInterval = 10

    enum Key {
        static let environment = "SubletteEnvironment"
        static let apiBaseURL = "SubletteAPIBaseURL"
        static let requestTimeout = "SubletteRequestTimeout"
    }

    /// The server on this Mac. Used when Info.plist has no usable address.
    static let fallback = AppConfiguration(
        environment: .local,
        apiBaseURL: URL(string: "http://localhost:8000")!
    )

    init(
        environment: AppEnvironment,
        apiBaseURL: URL,
        requestTimeout: TimeInterval = AppConfiguration.defaultRequestTimeout
    ) {
        self.environment = environment
        self.apiBaseURL = apiBaseURL
        self.requestTimeout = requestTimeout
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
            apiBaseURL: url,
            requestTimeout: Self.timeout(from: info[Key.requestTimeout])
        )
    }

    /// A timeout between 1 and 300 seconds from Info.plist, or the default.
    private static func timeout(from value: Any?) -> TimeInterval {
        let seconds: Double?
        if let text = value as? String {
            seconds = Double(text)
        } else if let number = value as? NSNumber {
            seconds = number.doubleValue
        } else {
            seconds = nil
        }
        guard let seconds, seconds >= 1, seconds <= 300 else {
            return defaultRequestTimeout
        }
        return seconds
    }

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        AppConfiguration(infoDictionary: bundle.infoDictionary)
    }
}
