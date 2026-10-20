import Foundation
import Observation

/// Builds the app's long-lived objects once and hands them to the screens.
@MainActor
@Observable
final class AppContainer {
    let configuration: AppConfiguration
    let preferences: Preferences
    let api: AccountAPI
    let listingsAPI: ListingsAPI
    let renterAPI: RenterAPI
    let deckAPI: DeckAPI
    let mapAPI: MapAPI
    let chatAPI: ChatAPI
    let campusLocator: CampusLocating
    let addressLocator: AddressLocating
    let uploader: PhotoUploading
    let appState: AppState
    let session: SessionModel
    let onboarding: OnboardingModel
    let serverStatus: ServerStatusModel
    let listerHome: ListerHomeModel
    let renterSearch: RenterSearchModel
    let outbox: SwipeOutbox
    let renterDeck: RenterDeckModel
    let listerDeck: ListerDeckModel
    let matchesModel: MatchesModel
    let renterMap: RenterMapModel
    let notifications: NotificationsModel
    /// Nil in previews and tests, which have no server to connect to.
    let liveEvents: LiveEvents?

    private let tokenManager: TokenManager

    init(
        configuration: AppConfiguration,
        preferences: Preferences,
        api: AccountAPI,
        listingsAPI: ListingsAPI,
        renterAPI: RenterAPI,
        deckAPI: DeckAPI,
        mapAPI: MapAPI,
        chatAPI: ChatAPI,
        notificationPermissions: NotificationPermissions,
        liveEvents: LiveEvents?,
        campusLocator: CampusLocating,
        addressLocator: AddressLocating,
        uploader: PhotoUploading,
        tokenManager: TokenManager,
        health: HealthChecking
    ) {
        self.configuration = configuration
        self.preferences = preferences
        self.api = api
        self.listingsAPI = listingsAPI
        self.renterAPI = renterAPI
        self.deckAPI = deckAPI
        self.mapAPI = mapAPI
        self.chatAPI = chatAPI
        self.liveEvents = liveEvents
        self.campusLocator = campusLocator
        self.addressLocator = addressLocator
        self.uploader = uploader
        self.tokenManager = tokenManager
        self.appState = AppState(preferences: preferences)
        let session = SessionModel(api: api, tokens: tokenManager, preferences: preferences)
        self.session = session
        self.onboarding = OnboardingModel(api: api, session: session)
        self.serverStatus = ServerStatusModel(health: health, configuration: configuration)
        self.listerHome = ListerHomeModel(api: listingsAPI)
        self.renterSearch = RenterSearchModel(api: renterAPI)
        let outbox = SwipeOutbox(api: deckAPI, preferences: preferences)
        self.outbox = outbox
        let renterDeck = RenterDeckModel(api: deckAPI, outbox: outbox)
        self.renterDeck = renterDeck
        self.listerDeck = ListerDeckModel(deckAPI: deckAPI, listingsAPI: listingsAPI, outbox: outbox)
        let matchesModel = MatchesModel(api: deckAPI, chatAPI: chatAPI, preferences: preferences)
        self.matchesModel = matchesModel
        let notifications = NotificationsModel(
            api: chatAPI,
            permissions: notificationPermissions,
            preferences: preferences,
            simulatorID: Runtime.isRunningUnitTests ? nil : NotificationsModel.currentSimulatorID
        )
        self.notifications = notifications
        session.willSignOut = { [weak notifications, weak liveEvents] in
            await liveEvents?.stop()
            await notifications?.willSignOut()
        }
        let renterMap = RenterMapModel(api: mapAPI, outbox: outbox)
        renterMap.onSwiped = { [weak renterDeck] listingID in
            renterDeck?.forget(listingID: listingID)
        }
        self.renterMap = renterMap
        liveEvents?.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    /// One live event, to every screen that shows it.
    private func handle(_ event: LiveEvent) {
        matchesModel.handle(event)
        if case .match(let match, isNew: true) = event, outbox.latestMatch == nil {
            // The renter's side of a match the lister just made.
            outbox.latestMatch = match
        }
    }

    /// Connects while the app is open and someone is signed in.
    func appBecameActive() async {
        guard !Runtime.isRunningUnitTests, session.user != nil else {
            return
        }
        liveEvents?.start()
        await notifications.didSignIn()
    }

    func appWentToBackground() {
        liveEvents?.stop()
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
            listingsAPI: LiveListingsAPI(client: signedInClient),
            renterAPI: LiveRenterAPI(client: signedInClient),
            deckAPI: LiveDeckAPI(client: signedInClient),
            mapAPI: LiveMapAPI(client: signedInClient),
            chatAPI: LiveChatAPI(client: signedInClient),
            notificationPermissions: SystemNotificationPermissions(),
            liveEvents: LiveEvents(client: signedInClient, tokens: tokenManager),
            campusLocator: AppleCampusLocator(),
            addressLocator: AppleAddressLocator(),
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

    func makePreferencesEditor(startAt step: PreferencesEditorModel.Step) -> PreferencesEditorModel {
        PreferencesEditorModel(
            profile: renterSearch.profile,
            schoolName: session.user?.school.name ?? "your school",
            api: renterAPI,
            campusLocator: campusLocator,
            startAt: step
        )
    }

    func makeListingEditor(for request: EditorRequest) -> ListingEditorModel {
        let listing: Listing?
        switch request {
        case .new: listing = nil
        case .edit(let existing): listing = existing
        }
        return ListingEditorModel(
            listing: listing,
            schoolName: session.user?.school.name ?? "your school",
            api: listingsAPI,
            uploader: uploader,
            locator: addressLocator
        )
    }
}
