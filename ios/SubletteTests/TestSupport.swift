import Foundation
import UserNotifications
import XCTest
@testable import Sublette

// Stand-ins for the server, shared by the tests.

enum Fixture {
    static let school = School(id: "school-1", name: "University of Washington")

    static let newUser = User(
        id: "user-1",
        email: "aditi@uw.edu",
        school: school,
        verified: true,
        firstName: nil,
        year: nil,
        program: nil,
        bio: nil,
        photoUrl: nil,
        gender: nil,
        smokes: nil,
        hasPets: nil,
        profileComplete: false
    )

    static let completeUser = User(
        id: "user-1",
        email: "aditi@uw.edu",
        school: school,
        verified: true,
        firstName: "Aditi",
        year: .junior,
        program: "Informatics",
        bio: "Tidy, quiet, plant person.",
        photoUrl: nil,
        gender: nil,
        smokes: false,
        hasPets: false,
        profileComplete: true
    )

    static func session(user: User = newUser) -> SessionResponse {
        SessionResponse(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 900, user: user)
    }

    static let presign = PresignedUpload(
        key: "profiles/user-1/abc.jpg",
        uploadUrl: "https://storage.example.test/profiles/user-1/abc.jpg?signature=x",
        method: "PUT",
        headers: ["Content-Type": "image/jpeg"],
        publicUrl: "https://photos.example.test/profiles/user-1/abc.jpg",
        maxBytes: 10_485_760
    )

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func listing(id: String = "listing-1", status: ListingStatus = .active) -> Listing {
        Listing(
            id: id,
            status: status,
            isOwner: true,
            address: "4500 University Way NE, Apt 3, Seattle, WA",
            latitude: 47.6588,
            longitude: -122.3130,
            publicLatitude: 47.6601,
            publicLongitude: -122.3119,
            rentCents: 120_000,
            depositCents: 50_000,
            utilitiesIncluded: true,
            startDate: "2027-01-14",
            endDate: "2027-04-08",
            spaceType: .privateRoom,
            bedrooms: 3,
            bathroom: .shared,
            furnished: true,
            laundry: true,
            parking: false,
            housematesStaying: 2,
            housematesNote: "Two grad students.",
            petsAllowed: false,
            smokingAllowed: false,
            householdGender: .women,
            genderPreference: .women,
            sameSchoolOnly: true,
            minStayDays: 56,
            landlordConsent: true,
            photos: (1...4).map { ListingPhoto(key: "listings/user-1/p\($0).jpg", url: "https://photos.example.test/p\($0).jpg") },
            lister: Lister(firstName: "Aditi", photoUrl: nil, schoolName: "University of Washington", verified: true)
        )
    }

    static func tokens(expiresIn seconds: TimeInterval, access: String = "access-1") -> AuthTokens {
        AuthTokens(
            accessToken: access,
            refreshToken: "refresh-1",
            accessTokenExpiresAt: now.addingTimeInterval(seconds)
        )
    }

    /// One of the real server responses in docs/contract/samples.
    static func sample(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: StubAccountAPI.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json"),
            "docs/contract/samples/\(name).json is not in the test bundle",
            file: file,
            line: line
        )
        return try Data(contentsOf: url)
    }

    static func serverError(_ status: Int, _ code: String, _ message: String) -> APIError {
        .server(status: status, code: code, message: message, fields: [])
    }
}

final class StubAccountAPI: AccountAPI, @unchecked Sendable {
    var requestCodeResult: Result<CodeRequestResponse, Error> =
        .success(CodeRequestResponse(expiresIn: 600, resendIn: 30))
    var verifyResult: Result<SessionResponse, Error> = .success(Fixture.session())
    var meResult: Result<User, Error> = .success(Fixture.completeUser)
    var updateResult: Result<User, Error> = .success(Fixture.completeUser)
    var setPhotoResult: Result<User, Error> = .success(Fixture.completeUser)
    var deleteResult: Result<Void, Error> = .success(())
    var presignResult: Result<PresignedUpload, Error> = .success(Fixture.presign)

    /// Runs in the middle of `me()`, to stand in for things that happen while
    /// the request is in the air.
    var duringMe: (() async -> Void)?

    private(set) var requestedCodes: [String] = []
    private(set) var verifications: [String] = []
    private(set) var updates: [ProfileUpdate] = []
    private(set) var photoKeys: [String?] = []
    private(set) var meCalls = 0
    private(set) var deleteCalls = 0

    func requestCode(email: String) async throws -> CodeRequestResponse {
        requestedCodes.append(email)
        return try requestCodeResult.get()
    }

    func verify(email: String, code: String) async throws -> SessionResponse {
        verifications.append("\(email) \(code)")
        return try verifyResult.get()
    }

    func me() async throws -> User {
        meCalls += 1
        await duringMe?()
        return try meResult.get()
    }

    func updateProfile(_ update: ProfileUpdate) async throws -> User {
        updates.append(update)
        return try updateResult.get()
    }

    func setPhoto(key: String?) async throws -> User {
        photoKeys.append(key)
        return try setPhotoResult.get()
    }

    func deleteAccount() async throws {
        deleteCalls += 1
        try deleteResult.get()
    }

    func presignProfilePhoto(contentType: String) async throws -> PresignedUpload {
        try presignResult.get()
    }

    func presignListingPhoto(contentType: String) async throws -> PresignedUpload {
        try presignResult.get()
    }
}

final class StubRefresher: TokenRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<TokenResponse, Error>
    private var storedCalls: [String] = []
    /// How long each refresh takes, so tests can overlap two of them.
    var delayNanoseconds: UInt64 = 0

    init(_ result: Result<TokenResponse, Error> = .success(
        TokenResponse(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 900)
    )) {
        storedResult = result
    }

    var result: Result<TokenResponse, Error> {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    var calls: [String] {
        lock.withLock { storedCalls }
    }

    func refresh(using refreshToken: String) async throws -> TokenResponse {
        lock.withLock { storedCalls.append(refreshToken) }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
    }
}

final class StubUploader: PhotoUploading, @unchecked Sendable {
    var result: Result<String, Error> = .success("profiles/user-1/abc.jpg")
    /// Listing photo uploads answer from this list in turn; when it runs out, `result`.
    var listingResults: [Result<String, Error>] = []
    private(set) var uploads: [Data] = []
    private(set) var listingUploads: [Data] = []

    func uploadProfilePhoto(_ jpeg: Data) async throws -> String {
        uploads.append(jpeg)
        return try result.get()
    }

    func uploadListingPhoto(_ jpeg: Data) async throws -> String {
        listingUploads.append(jpeg)
        if !listingResults.isEmpty {
            return try listingResults.removeFirst().get()
        }
        return "listings/user-1/photo-\(listingUploads.count).jpg"
    }
}

final class StubListingsAPI: ListingsAPI, @unchecked Sendable {
    var pages: [Result<ListingPage, Error>] = []
    var createResult: Result<Listing, Error>?
    var updateResult: Result<Listing, Error>?
    var statusResult: Result<Listing, Error>?

    private(set) var requestedCursors: [String?] = []
    private(set) var created: [ListingForm] = []
    private(set) var updated: [(id: String, form: ListingForm)] = []
    private(set) var statusChanges: [(id: String, status: ListingStatus)] = []

    func myListings(cursor: String?) async throws -> ListingPage {
        requestedCursors.append(cursor)
        guard !pages.isEmpty else {
            return ListingPage(items: [], nextCursor: nil)
        }
        return try pages.removeFirst().get()
    }

    func listing(id: String) async throws -> Listing {
        Fixture.listing(id: id)
    }

    func create(_ form: ListingForm) async throws -> Listing {
        created.append(form)
        return try (createResult ?? .success(Fixture.listing(id: "new-1", status: .draft))).get()
    }

    func update(id: String, _ form: ListingForm) async throws -> Listing {
        updated.append((id, form))
        return try (updateResult ?? .success(Fixture.listing(id: id, status: .draft))).get()
    }

    func setStatus(id: String, _ status: ListingStatus) async throws -> Listing {
        statusChanges.append((id, status))
        return try (statusResult ?? .success(Fixture.listing(id: id, status: status))).get()
    }
}

final class StubLocator: AddressLocating, @unchecked Sendable {
    var result: Result<LocatedAddress, Error> = .success(
        LocatedAddress(
            coordinate: Coordinate(latitude: 47.6588, longitude: -122.3130),
            formatted: "4500 University Way NE, Seattle, WA, 98105"
        )
    )
    private(set) var lookups: [String] = []

    func locate(_ address: String) async throws -> LocatedAddress {
        lookups.append(address)
        return try result.get()
    }
}

/// A yes/no a test can flip from inside a `@Sendable` closure.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var isSet: Bool {
        lock.withLock { stored }
    }

    func set() {
        lock.withLock { stored = true }
    }
}

/// Builds a signed-out session with fakes behind it.
@MainActor
struct TestSession {
    let api = StubAccountAPI()
    let refresher = StubRefresher()
    let store: InMemoryTokenStore
    let preferences = Preferences.ephemeral()
    let tokens: TokenManager
    let session: SessionModel

    init(savedTokens: AuthTokens? = nil) {
        store = InMemoryTokenStore(savedTokens)
        tokens = TokenManager(store: store, refresher: refresher, now: { Fixture.now })
        session = SessionModel(
            api: api,
            tokens: tokens,
            preferences: preferences,
            now: { Fixture.now }
        )
    }
}

final class StubRenterAPI: RenterAPI, @unchecked Sendable {
    var loadResults: [Result<RenterProfile, Error>] = []
    var saveResult: Result<RenterProfile, Error>?
    private(set) var saved: [RenterProfileForm] = []
    private(set) var loads = 0

    func renterProfile() async throws -> RenterProfile {
        loads += 1
        guard !loadResults.isEmpty else {
            return .empty
        }
        return try loadResults.removeFirst().get()
    }

    func saveRenterProfile(_ form: RenterProfileForm) async throws -> RenterProfile {
        saved.append(form)
        if let saveResult {
            return try saveResult.get()
        }
        // Echo it back, as the server does.
        return RenterProfile(
            startDate: form.startDate,
            endDate: form.endDate,
            flexibilityDays: form.flexibilityDays,
            maxRentCents: form.maxRentCents,
            preferences: form.preferences,
            pin: form.pin,
            notifyNewListings: form.notifyNewListings,
            complete: form.startDate != nil && form.endDate != nil && form.maxRentCents != nil && form.pin != nil,
            updatedAt: Fixture.now
        )
    }
}

final class StubCampusLocator: CampusLocating, @unchecked Sendable {
    var result: Result<Coordinate, Error> = .success(Coordinate(latitude: 47.6553, longitude: -122.3035))
    private(set) var searches: [String] = []

    func locateCampus(named schoolName: String) async throws -> Coordinate {
        searches.append(schoolName)
        return try result.get()
    }
}

final class StubDeckAPI: DeckAPI, @unchecked Sendable {
    var deckPages: [Result<DeckPage, Error>] = []
    var diagnosticsResult: Result<DeckDiagnostics, Error> = .success(
        DeckDiagnostics(inArea: 0, eligible: 0, seen: 0, topMustHave: nil, blockers: [])
    )
    /// Answers for swipes, in order. When empty, every swipe is accepted.
    var swipeResults: [Result<SwipeResult, Error>] = []
    var undoResult: Result<Void, Error> = .success(())
    var saveResult: Result<Void, Error> = .success(())
    var renterPages: [String: [InterestedRenter]] = [:]
    var matchesResult: Result<MatchPage, Error> = .success(MatchPage(items: []))
    var savedResult: Result<SavedPage, Error> = .success(SavedPage(items: []))

    private(set) var swipes: [SwipeRequest] = []
    private(set) var undone: [String] = []
    private(set) var savedIDs: [String] = []
    private(set) var unsavedIDs: [String] = []
    private(set) var deckCalls = 0

    func deck(limit: Int) async throws -> DeckPage {
        deckCalls += 1
        guard !deckPages.isEmpty else {
            return DeckPage(items: [])
        }
        return try deckPages.removeFirst().get()
    }

    func diagnostics() async throws -> DeckDiagnostics {
        try diagnosticsResult.get()
    }

    func swipe(_ request: SwipeRequest) async throws -> SwipeResult {
        swipes.append(request)
        if !swipeResults.isEmpty {
            return try swipeResults.removeFirst().get()
        }
        return Fixture.swipeResult(for: request)
    }

    func undo(swipeID: String) async throws -> Swipe {
        undone.append(swipeID)
        try undoResult.get()
        return Fixture.swipeResult(for: SwipeRequest(listingId: "x", action: .pass, swipeId: swipeID)).swipe
    }

    func save(listingID: String) async throws {
        savedIDs.append(listingID)
        try saveResult.get()
    }

    func unsave(listingID: String) async throws {
        unsavedIDs.append(listingID)
    }

    func saved() async throws -> SavedPage {
        try savedResult.get()
    }

    func interestedRenters(listingID: String) async throws -> InterestedRenterPage {
        InterestedRenterPage(items: renterPages[listingID] ?? [])
    }

    func matches() async throws -> MatchPage {
        try matchesResult.get()
    }
}

extension Fixture {
    static func deckItem(_ id: String, score: Int = 80) -> DeckItem {
        DeckItem(
            listing: listing(id: id),
            score: score,
            band: score >= 75 ? .strong : score >= 50 ? .partial : .other,
            summary: "Fits your dates, $100 under budget and 0.5 mi from your pin.",
            reasons: ["Fits your dates", "$100 under budget", "0.5 mi from your pin"],
            distanceM: 800
        )
    }

    static func swipeResult(for request: SwipeRequest, match: Match? = nil, created: Bool = true) -> SwipeResult {
        SwipeResult(
            swipe: Swipe(
                id: "server-\(request.swipeId)",
                swipeId: request.swipeId,
                side: request.renterId == nil ? .renter : .lister,
                action: request.action,
                listingId: request.listingId,
                renterId: request.renterId ?? "user-1",
                createdAt: now
            ),
            match: match,
            created: created
        )
    }

    static func match(id: String = "match-1", listingID: String = "listing-1") -> Match {
        Match(
            id: id,
            role: .lister,
            listing: listing(id: listingID),
            renter: Person(id: "user-2", firstName: "Sam", photoUrl: nil, schoolName: "UW", verified: true),
            lister: Person(id: "user-1", firstName: "Aditi", photoUrl: nil, schoolName: "UW", verified: true),
            createdAt: now
        )
    }

    static func interestedRenter(_ id: String) -> InterestedRenter {
        InterestedRenter(
            renter: RenterCard(
                id: id, firstName: "Sam", photoUrl: nil, year: .senior, program: "Biology",
                bio: nil, schoolName: "UW", verified: true
            ),
            startDate: "2027-06-15",
            endDate: "2027-09-01",
            likedAt: now,
            fits: ["Stays 78 days of your dates"]
        )
    }
}

final class StubMapAPI: MapAPI, @unchecked Sendable {
    var pages: [Result<MapPage, Error>] = []
    var cardResult: Result<MapCard, Error>?
    private(set) var regions: [MapRegion] = []

    func pins(in region: MapRegion) async throws -> MapPage {
        regions.append(region)
        guard !pages.isEmpty else {
            return MapPage(items: [], truncated: false)
        }
        return try pages.removeFirst().get()
    }

    func card(listingID: String) async throws -> MapCard {
        try (cardResult ?? .success(MapCard(item: Fixture.deckItem(listingID), state: .new))).get()
    }
}

extension Fixture {
    static func pin(
        _ id: String,
        latitude: Double = 47.66,
        longitude: Double = -122.31,
        band: ScoreBand = .strong,
        state: PinState = .new
    ) -> MapPin {
        MapPin(id: id, latitude: latitude, longitude: longitude, exact: state == .matched,
               score: 80, band: band, state: state, rentCents: 100_000)
    }
}

final class StubChatAPI: ChatAPI, @unchecked Sendable {
    var pages: [Result<MessagePage, Error>] = []
    /// Answers for sends, in order. When empty, every message is accepted.
    var sendResults: [Result<Void, Error>] = []
    var checklistResult: Result<Void, Error> = .success(())
    var matchResult: Result<Match, Error> = .success(Fixture.match(id: "fetched"))
    var registerResult: Result<Void, Error> = .success(())

    private(set) var sent: [MessageRequest] = []
    private(set) var readCalls: [String] = []
    private(set) var checklistChanges: [ChecklistChange] = []
    private(set) var filledCalls = 0
    private(set) var registered: [DeviceRequest] = []
    private(set) var unregistered: [String] = []
    private(set) var pageRequests: [String?] = []

    func match(id: String) async throws -> Match {
        try matchResult.get()
    }

    func messages(matchID: String, before: String?) async throws -> MessagePage {
        pageRequests.append(before)
        guard !pages.isEmpty else {
            return MessagePage(items: [], hasMore: false)
        }
        return try pages.removeFirst().get()
    }

    func send(matchID: String, _ request: MessageRequest) async throws -> ChatMessage {
        sent.append(request)
        if !sendResults.isEmpty {
            try sendResults.removeFirst().get()
        }
        return Fixture.message(id: "server-\(request.messageId)", body: request.body, mine: true, messageID: request.messageId)
    }

    func markRead(matchID: String) async throws {
        readCalls.append(matchID)
    }

    func updateChecklist(matchID: String, _ change: ChecklistChange) async throws -> Match {
        checklistChanges.append(change)
        try checklistResult.get()
        var match = Fixture.match(id: matchID)
        if let value = change.tourDone { match.checklist.tourDone = value }
        return match
    }

    func confirmFilled(matchID: String) async throws -> Match {
        filledCalls += 1
        var match = Fixture.match(id: matchID)
        match.filled = Filled(renterConfirmed: false, listerConfirmed: true, completed: false)
        return match
    }

    func registerDevice(_ request: DeviceRequest) async throws {
        registered.append(request)
        try registerResult.get()
    }

    func unregisterDevice(token: String) async throws {
        unregistered.append(token)
    }
}

final class StubPermissions: NotificationPermissions, @unchecked Sendable {
    var current: UNAuthorizationStatus
    var grants = true
    private(set) var requests = 0
    private(set) var registrations = 0

    init(_ status: UNAuthorizationStatus) {
        current = status
    }

    func status() async -> UNAuthorizationStatus { current }

    func request() async -> Bool {
        requests += 1
        current = grants ? .authorized : .denied
        return grants
    }

    func registerForRemoteNotifications() {
        registrations += 1
    }
}

extension Fixture {
    static func message(
        id: String, body: String = "Hello", mine: Bool = false, matchID: String = "match-1", messageID: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, messageId: messageID, matchId: matchID, senderId: mine ? "user-1" : "user-2",
            mine: mine, body: body, createdAt: now
        )
    }
}

final class StubSafetyAPI: SafetyAPI, @unchecked Sendable {
    var reportResult: Result<Void, Error> = .success(())
    var blockResult: Result<Void, Error> = .success(())
    var blockedResult: Result<BlockPage, Error> = .success(BlockPage(items: []))
    var termsResult: Result<User, Error> = .success(Fixture.completeUser)

    private(set) var reports: [ReportRequest] = []
    private(set) var blocks: [BlockSubject] = []
    private(set) var unblocked: [String] = []
    private(set) var acceptedVersions: [String] = []

    func report(_ request: ReportRequest) async throws -> ReportReceipt {
        reports.append(request)
        try reportResult.get()
        return ReportReceipt(id: "r1", target: request.target, reason: request.reason, status: "open", createdAt: Fixture.now)
    }

    func block(_ subject: BlockSubject) async throws {
        blocks.append(subject)
        try blockResult.get()
    }

    func blocked() async throws -> BlockPage {
        try blockedResult.get()
    }

    func unblock(userID: String) async throws {
        unblocked.append(userID)
    }

    func acceptTerms(version: String) async throws -> User {
        acceptedVersions.append(version)
        return try termsResult.get()
    }
}
