import Foundation
import Observation

/// Builds the app's long-lived objects once and hands them to the screens.
@MainActor
@Observable
final class AppContainer {
    let configuration: AppConfiguration
    let preferences: Preferences
    let api: AccountAPI
    let uploader: PhotoUploading
    let appState: AppState
    let session: SessionModel
    let onboarding: OnboardingModel
    let serverStatus: ServerStatusModel

    private let tokenManager: TokenManager

    init(
        configuration: AppConfiguration,
        preferences: Preferences,
        api: AccountAPI,
        uploader: PhotoUploading,
        tokenManager: TokenManager,
        health: HealthChecking
    ) {
        self.configuration = configuration
        self.preferences = preferences
        self.api = api
        self.uploader = uploader
        self.tokenManager = tokenManager
        self.appState = AppState(preferences: preferences)
        let session = SessionModel(api: api, tokens: tokenManager, preferences: preferences)
        self.session = session
        self.onboarding = OnboardingModel(api: api, session: session)
        self.serverStatus = ServerStatusModel(health: health, configuration: configuration)
    }

    /// The real thing: talks to the server named in the build settings and
    /// keeps tokens in the Keychain.
    static func live() -> AppContainer {
        let configuration = AppConfiguration.load()
        let preferences = Preferences()
        let tokenStore = KeychainTokenStore()

        let timeout = configuration.requestTimeout
        let openClient = APIClient(
            baseURL: configuration.apiBaseURL,
            session: APIClient.makeSession(timeout: timeout)
        )
        // The refresher uses the client that sends no token; the token manager
        // then feeds the client that does.
        let refresher = LiveAccountAPI(openClient: openClient, signedInClient: openClient)
        let tokenManager = TokenManager(store: tokenStore, refresher: refresher)
        let signedInClient = APIClient(
            baseURL: configuration.apiBaseURL,
            session: APIClient.makeSession(timeout: timeout),
            tokens: tokenManager
        )
        let api = LiveAccountAPI(openClient: openClient, signedInClient: signedInClient)

        return AppContainer(
            configuration: configuration,
            preferences: preferences,
            api: api,
            uploader: PhotoUploader(api: api, session: APIClient.makeSession(timeout: timeout)),
            tokenManager: tokenManager,
            health: openClient
        )
    }

    /// Called once when the first screen appears.
    func start() async {
        // Unit tests launch the whole app as their host. It must not sign in or
        // call a server then.
        guard !Runtime.isRunningUnitTests else {
            return
        }
        await tokenManager.prepare(preferences: preferences)
        await tokenManager.setSessionEndedHandler { [weak session] in
            await session?.sessionEnded()
        }
        await session.restore()
    }

    func makeProfileForm(for user: User) -> ProfileFormModel {
        ProfileFormModel(user: user, api: api, uploader: uploader, session: session)
    }
}
