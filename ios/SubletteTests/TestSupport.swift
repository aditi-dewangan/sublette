import Foundation
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
