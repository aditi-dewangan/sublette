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
    let safetyAPI: SafetyAPI
    let releaseAPI: ReleaseAPI
    let assistantAPI: AssistantAPI
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
    let safety: SafetyModel
    let analytics: AnalyticsModel
    let assistant: AssistantModel
    /// Deck cards, matches, saved listings and chats kept for offline use.
    let offlineCache: OfflineStoring
    let messageOutbox: MessageOutbox
    /// Nil in previews and tests, which have no server to connect to.
    let liveEvents: LiveEvents?

    private let tokenManager: TokenManager
    /// Kept alive while the app runs; MetricKit holds it weakly.
    @ObservationIgnored private var crashReporter: CrashReporter?

    init(
        configuration: AppConfiguration,
        preferences: Preferences,
        api: AccountAPI,
        listingsAPI: ListingsAPI,
        renterAPI: RenterAPI,
        deckAPI: DeckAPI,
        mapAPI: MapAPI,
        chatAPI: ChatAPI,
        safetyAPI: SafetyAPI,
        releaseAPI: ReleaseAPI,
        assistantAPI: AssistantAPI,
        notificationPermissions: NotificationPermissions,
        liveEvents: LiveEvents?,
        campusLocator: CampusLocating,
        addressLocator: AddressLocating,
        uploader: PhotoUploading,
        tokenManager: TokenManager,
        health: HealthChecking,
        offlineCache: OfflineStoring? = nil
    ) {
        self.configuration = configuration
        self.preferences = preferences
        self.api = api
        self.listingsAPI = listingsAPI
        self.renterAPI = renterAPI
        self.deckAPI = deckAPI
        self.mapAPI = mapAPI
        self.chatAPI = chatAPI
        self.safetyAPI = safetyAPI
        self.releaseAPI = releaseAPI
        self.assistantAPI = assistantAPI
        self.liveEvents = liveEvents
        self.campusLocator = campusLocator
        self.addressLocator = addressLocator
        self.uploader = uploader
        self.tokenManager = tokenManager
        self.appState = AppState(preferences: preferences)
        let cache = offlineCache ?? OfflineCache(inMemory: true)
        self.offlineCache = cache
        let messageOutbox = MessageOutbox(api: chatAPI, cache: cache)
        self.messageOutbox = messageOutbox
        let session = SessionModel(api: api, tokens: tokenManager, preferences: preferences)
        self.session = session
        self.onboarding = OnboardingModel(api: api, session: session)
        self.serverStatus = ServerStatusModel(health: health, configuration: configuration)
        self.listerHome = ListerHomeModel(api: listingsAPI)
        self.renterSearch = RenterSearchModel(api: renterAPI)
        let outbox = SwipeOutbox(api: deckAPI, preferences: preferences)
        self.outbox = outbox
        let renterDeck = RenterDeckModel(api: deckAPI, outbox: outbox, cache: cache)
        self.renterDeck = renterDeck
        self.listerDeck = ListerDeckModel(deckAPI: deckAPI, listingsAPI: listingsAPI, outbox: outbox)
        let matchesModel = MatchesModel(
            api: deckAPI, chatAPI: chatAPI, preferences: preferences, cache: cache, outbox: messageOutbox
        )
        self.matchesModel = matchesModel
        let notifications = NotificationsModel(
            api: chatAPI,
            permissions: notificationPermissions,
            preferences: preferences,
            simulatorID: Runtime.isRunningUnitTests ? nil : NotificationsModel.currentSimulatorID
        )
        self.notifications = notifications
        let safety = SafetyModel(api: safetyAPI)
        self.safety = safety
        let analytics = AnalyticsModel(api: releaseAPI, preferences: preferences)
        analytics.isSignedIn = { [weak session] in session?.user != nil }
        self.analytics = analytics
        session.willSignOut = { [weak notifications, weak liveEvents, weak safety, weak session, preferences] in
            liveEvents?.stop()
            await notifications?.willSignOut()
            safety?.reset()
            // A shared phone keeps nothing of the last account's.
            if let accountID = session?.user?.id ?? preferences.cachedUser?.id {
                cache.removeAll(accountID: accountID)
            }
        }
        let renterMap = RenterMapModel(api: mapAPI, outbox: outbox)
        renterMap.onSwiped = { [weak renterDeck] listingID in
            renterDeck?.forget(listingID: listingID)
        }
        self.renterMap = renterMap
        let assistant = AssistantModel(api: assistantAPI, outbox: outbox)
        let renterSearch = self.renterSearch
        assistant.saveChanges = { [weak renterSearch] changes in
            await renterSearch?.apply(changes) ?? false
        }
        assistant.onLiked = { [weak renterDeck] listingID in
            renterDeck?.forget(listingID: listingID)
        }
        self.assistant = assistant
        let signOutSoFar = session.willSignOut
        session.willSignOut = { [weak assistant] in
            await signOutSoFar?()
            assistant?.reset()
        }
        liveEvents?.onEvent = { [weak self] event in
            self?.handle(event)
        }
        liveEvents?.onSuspended = { [weak self] in
            // Ask the server why; its answer puts up the suspended screen.
            Task { _ = try? await self?.api.me() }
        }
        safety.onBlocksChanged = { [weak self] in
            await self?.blocksChanged()
        }
    }

    /// After a block or unblock: every list that shows people catches up.
    private func blocksChanged() async {
        await matchesModel.load()
        if appState.mode == .renter {
            await renterDeck.reload()
            await renterMap.load()
        } else {
            await listerDeck.load()
        }
    }

    /// The link that opens a listing's public page, for sharing.
    func shareURL(for listing: Listing) -> URL? {
        pageURL(.listingShare(listing.id))
    }

    /// A web page on the server, such as the terms of service.
    func pageURL(_ endpoint: Endpoint) -> URL? {
        APIClient(baseURL: configuration.apiBaseURL).url(for: endpoint)
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
        await messageOutbox.flush()
        await analytics.appOpened()
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
            safetyAPI: LiveSafetyAPI(client: signedInClient),
            releaseAPI: LiveReleaseAPI(client: signedInClient),
            assistantAPI: LiveAssistantAPI(client: signedInClient),
            notificationPermissions: SystemNotificationPermissions(),
            liveEvents: LiveEvents(client: signedInClient, tokens: tokenManager),
            campusLocator: AppleCampusLocator(),
            addressLocator: AppleAddressLocator(),
            uploader: PhotoUploader(api: api, session: APIClient.makeSession(timeout: timeout)),
            tokenManager: tokenManager,
            health: openClient,
            offlineCache: OfflineCache()
        )
    }

    /// Called once when the first screen appears.
    func start() async {
        // Unit tests launch the whole app as their host. It must not sign in or
        // call a server then.
        guard !Runtime.isRunningUnitTests else {
            return
        }
        let reporter = CrashReporter { [weak self] reports in
            Task { @MainActor in await self?.analytics.received(reports) }
        }
        reporter.start()
        crashReporter = reporter
        await tokenManager.prepare(preferences: preferences)
        await tokenManager.setSessionEndedHandler { [weak session] in
            await session?.sessionEnded()
        }
        await tokenManager.setSuspendedHandler { [weak session] message in
            await session?.showSuspended(message)
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
