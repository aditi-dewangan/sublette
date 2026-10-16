import SwiftUI

// Everything SwiftUI previews need to draw a screen without a server.
//
// Not wrapped in `#if DEBUG` on purpose: `#Preview` blocks are compiled in
// Staging and Release builds too, and they refer to the names in this file.

enum PreviewData {
    static let school = School(id: "school-1", name: "University of Washington")

    static let aditi = User(
        id: "user-1",
        email: "aditi@uw.edu",
        school: school,
        verified: true,
        firstName: "Aditi",
        year: .junior,
        program: "Informatics",
        bio: "Winter internship in Austin. Tidy, quiet, plant person.",
        photoUrl: nil,
        gender: nil,
        smokes: false,
        hasPets: false,
        profileComplete: true
    )

    static let newUser = User(
        id: "user-2",
        email: "sam@northeastern.edu",
        school: School(id: "school-2", name: "Northeastern University"),
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
}

/// Answers from memory. Photo uploads are "unavailable", which also shows how
/// the form looks when storage is down.
struct PreviewAccountAPI: AccountAPI {
    var user: User = PreviewData.aditi

    func requestCode(email: String) async throws -> CodeRequestResponse {
        CodeRequestResponse(expiresIn: 600, resendIn: 30)
    }

    func verify(email: String, code: String) async throws -> SessionResponse {
        SessionResponse(accessToken: "preview", refreshToken: "preview", expiresIn: 900, user: user)
    }

    func me() async throws -> User {
        user
    }

    func updateProfile(_ update: ProfileUpdate) async throws -> User {
        user
    }

    func setPhoto(key: String?) async throws -> User {
        user
    }

    func deleteAccount() async throws {}

    func presignListingPhoto(contentType: String) async throws -> PresignedUpload {
        try await presignProfilePhoto(contentType: contentType)
    }

    func presignProfilePhoto(contentType: String) async throws -> PresignedUpload {
        throw APIError.server(
            status: 503,
            code: "uploads_unavailable",
            message: "Photo uploads aren't available right now. You can add a photo later.",
            fields: []
        )
    }
}

private struct PreviewRefresher: TokenRefreshing {
    func refresh(using refreshToken: String) async throws -> TokenResponse {
        throw APIError.unreachable
    }
}

private struct PreviewUploader: PhotoUploading {
    func uploadProfilePhoto(_ jpeg: Data) async throws -> String {
        throw APIError.unreachable
    }

    func uploadListingPhoto(_ jpeg: Data) async throws -> String {
        throw APIError.unreachable
    }
}

extension PreviewData {
    static let listing = Listing(
        id: "listing-1",
        status: .active,
        isOwner: true,
        address: "4500 University Way NE, Apt 3, Seattle, WA",
        latitude: 47.6588,
        longitude: -122.3130,
        publicLatitude: 47.6601,
        publicLongitude: -122.3119,
        rentCents: 120_000,
        depositCents: 50_000,
        utilitiesIncluded: true,
        startDate: "2027-01-04",
        endDate: "2027-03-28",
        spaceType: .privateRoom,
        bedrooms: 3,
        bathroom: .shared,
        furnished: true,
        laundry: true,
        parking: false,
        housematesStaying: 2,
        housematesNote: "Two grad students, quiet, both cook.",
        petsAllowed: false,
        smokingAllowed: false,
        householdGender: .mixed,
        genderPreference: .anyone,
        sameSchoolOnly: false,
        minStayDays: 56,
        landlordConsent: true,
        photos: [],
        lister: Lister(firstName: "Aditi", photoUrl: nil, schoolName: "University of Washington", verified: true)
    )

    static var draft: Listing {
        Listing(
            id: "listing-2", status: .draft, isOwner: true, address: nil, latitude: nil, longitude: nil,
            publicLatitude: nil, publicLongitude: nil, rentCents: 95_000, depositCents: 0,
            utilitiesIncluded: false, startDate: nil, endDate: nil, spaceType: .entireUnit,
            bedrooms: 0, bathroom: .own, furnished: false, laundry: false, parking: false,
            housematesStaying: nil, housematesNote: nil, petsAllowed: nil, smokingAllowed: nil,
            householdGender: nil,
            genderPreference: .anyone, sameSchoolOnly: false, minStayDays: 0, landlordConsent: nil,
            photos: [], lister: listing.lister
        )
    }
}

/// Answers from memory: two listings, and every change is accepted.
struct PreviewListingsAPI: ListingsAPI {
    func myListings(cursor: String?) async throws -> ListingPage {
        ListingPage(items: [PreviewData.listing, PreviewData.draft], nextCursor: nil)
    }

    func listing(id: String) async throws -> Listing {
        PreviewData.listing
    }

    func create(_ form: ListingForm) async throws -> Listing {
        PreviewData.draft
    }

    func update(id: String, _ form: ListingForm) async throws -> Listing {
        PreviewData.listing
    }

    func setStatus(id: String, _ status: ListingStatus) async throws -> Listing {
        var listing = PreviewData.listing
        listing.status = status
        return listing
    }
}

extension PreviewData {
    static let renterProfile = RenterProfile(
        startDate: "2027-06-15",
        endDate: "2027-09-01",
        flexibilityDays: 7,
        maxRentCents: 110_000,
        preferences: [
            Preference(field: .spaceType, value: .spaceTypes([.privateRoom, .entireUnit]), importance: .must),
            Preference(field: .furnished, value: .yes, importance: .must),
            Preference(field: .laundry, value: .yes, importance: .nice),
            Preference(field: .housemateCount, value: .count(2), importance: .nice),
            Preference(field: .housemateGender, value: .gender(.women), importance: .must),
        ],
        pin: SearchPin(latitude: 47.6553, longitude: -122.3035, radiusM: SearchPin.defaultRadiusM),
        notifyNewListings: false,
        complete: true,
        updatedAt: Date(timeIntervalSince1970: 1_799_000_000)
    )
}

/// Answers from memory. A new renter starts with nothing saved.
struct PreviewRenterAPI: RenterAPI {
    var profile: RenterProfile = .empty

    func renterProfile() async throws -> RenterProfile {
        profile
    }

    func saveRenterProfile(_ form: RenterProfileForm) async throws -> RenterProfile {
        PreviewData.renterProfile
    }
}

extension PreviewData {
    /// A listing as a renter sees it: no exact address.
    static var publicListing: Listing {
        Listing(
            id: "listing-3", status: .active, isOwner: false, address: nil, latitude: nil, longitude: nil,
            publicLatitude: 47.6601, publicLongitude: -122.3119,
            rentCents: 105_000, depositCents: 0, utilitiesIncluded: true, startDate: "2027-06-15",
            endDate: "2027-09-01", spaceType: .privateRoom, bedrooms: 3, bathroom: .shared,
            furnished: true, laundry: true, parking: false, housematesStaying: 2,
            housematesNote: "Two grad students.", petsAllowed: false, smokingAllowed: false,
            householdGender: .women, genderPreference: .anyone, sameSchoolOnly: false,
            minStayDays: 0, landlordConsent: true, photos: [],
            lister: Lister(firstName: "Lee", photoUrl: nil, schoolName: "University of Washington", verified: true)
        )
    }

    static let deckItem = DeckItem(
        listing: publicListing,
        score: 92,
        band: .strong,
        summary: "Fits your dates, $50 under budget and 0.4 mi from your pin. Furnished and in-unit laundry.",
        reasons: ["Fits your dates", "$50 under budget", "0.4 mi from your pin", "Furnished and in-unit laundry"],
        distanceM: 640
    )

    static let interestedRenter = InterestedRenter(
        renter: RenterCard(
            id: "user-1", firstName: "Aditi", photoUrl: nil, year: .junior, program: "Informatics",
            bio: "Winter internship in Austin. Tidy, quiet, plant person.",
            schoolName: "University of Washington", verified: true
        ),
        startDate: "2027-06-15",
        endDate: "2027-09-01",
        likedAt: Date(timeIntervalSince1970: 1_799_000_000),
        fits: ["Stays 78 days of your dates", "Verified University of Washington student", "No pets", "Doesn't smoke"]
    )

    static let match = Match(
        id: "match-1",
        role: .lister,
        listing: publicListing,
        renter: Person(id: "user-1", firstName: "Aditi", photoUrl: nil, schoolName: "University of Washington", verified: true),
        lister: Person(id: "user-3", firstName: "Lee", photoUrl: nil, schoolName: "University of Washington", verified: true),
        createdAt: Date(timeIntervalSince1970: 1_799_000_000)
    )
}

/// A deck from memory: one card, one interested renter, and every swipe accepted.
struct PreviewDeckAPI: DeckAPI {
    func deck(limit: Int) async throws -> DeckPage {
        DeckPage(items: [PreviewData.deckItem])
    }

    func diagnostics() async throws -> DeckDiagnostics {
        DeckDiagnostics(inArea: 0, eligible: 0, seen: 1, topMustHave: nil, blockers: [])
    }

    func swipe(_ request: SwipeRequest) async throws -> SwipeResult {
        SwipeResult(
            swipe: Swipe(
                id: request.swipeId, swipeId: request.swipeId,
                side: request.renterId == nil ? .renter : .lister, action: request.action,
                listingId: request.listingId, renterId: request.renterId ?? "user-1", createdAt: Date()
            ),
            match: request.renterId != nil && request.action == .like ? PreviewData.match : nil,
            created: true
        )
    }

    func undo(swipeID: String) async throws -> Swipe {
        Swipe(id: swipeID, swipeId: swipeID, side: .renter, action: .pass, listingId: "listing-3", renterId: "user-1", createdAt: Date())
    }

    func save(listingID: String) async throws {}

    func unsave(listingID: String) async throws {}

    func saved() async throws -> SavedPage {
        SavedPage(items: [PreviewData.publicListing])
    }

    func interestedRenters(listingID: String) async throws -> InterestedRenterPage {
        InterestedRenterPage(items: [PreviewData.interestedRenter])
    }

    func matches() async throws -> MatchPage {
        MatchPage(items: [PreviewData.match])
    }
}

/// A few pins around the University of Washington, one of each kind.
struct PreviewMapAPI: MapAPI {
    func pins(in region: MapRegion) async throws -> MapPage {
        let offsets: [(Double, Double, ScoreBand, PinState)] = [
            (0.004, 0.002, .strong, .new), (-0.003, 0.004, .partial, .new), (0.006, -0.005, .other, .new),
            (-0.006, -0.003, .strong, .liked), (0.001, -0.007, .partial, .saved), (0.008, 0.006, .strong, .matched),
        ]
        return MapPage(
            items: offsets.enumerated().map { index, offset in
                MapPin(
                    id: "pin-\(index)", latitude: 47.6553 + offset.0, longitude: -122.3035 + offset.1,
                    exact: offset.3 == .matched, score: offset.2 == .strong ? 88 : offset.2 == .partial ? 62 : 35,
                    band: offset.2, state: offset.3, rentCents: 95_000 + index * 10_000
                )
            },
            truncated: false
        )
    }

    func card(listingID: String) async throws -> MapCard {
        MapCard(item: PreviewData.deckItem, state: .new)
    }
}

/// Every campus is at the same spot, near the University of Washington.
struct PreviewCampusLocator: CampusLocating {
    func locateCampus(named schoolName: String) async throws -> Coordinate {
        Coordinate(latitude: 47.6553, longitude: -122.3035)
    }
}

/// Finds every address at the same spot, near the University of Washington.
struct PreviewAddressLocator: AddressLocating {
    func locate(_ address: String) async throws -> LocatedAddress {
        LocatedAddress(
            coordinate: Coordinate(latitude: 47.6588, longitude: -122.3130),
            formatted: "4500 University Way NE, Seattle, WA, 98105"
        )
    }
}

private struct PreviewHealthCheck: HealthChecking {
    func health() async throws -> HealthStatus {
        HealthStatus(
            status: "ok",
            version: "0.2.0",
            environment: "local",
            database: .init(reachable: true, postgis: "3.4.2")
        )
    }
}

extension AppContainer {
    /// A container with nothing real behind it. Pass a user to be signed in as them.
    static func preview(signedInAs user: User? = PreviewData.aditi) -> AppContainer {
        let preferences = Preferences.ephemeral()
        if let user, user.profileComplete {
            preferences.usersWhoChoseAMode = [user.id]
        }
        let container = AppContainer(
            configuration: .fallback,
            preferences: preferences,
            api: PreviewAccountAPI(user: user ?? PreviewData.newUser),
            listingsAPI: PreviewListingsAPI(),
            renterAPI: PreviewRenterAPI(),
            deckAPI: PreviewDeckAPI(),
            mapAPI: PreviewMapAPI(),
            campusLocator: PreviewCampusLocator(),
            addressLocator: PreviewAddressLocator(),
            uploader: PreviewUploader(),
            tokenManager: TokenManager(store: InMemoryTokenStore(), refresher: PreviewRefresher()),
            health: PreviewHealthCheck()
        )
        if let user {
            container.session.update(user)
        }
        return container
    }
}

extension View {
    /// Gives a preview everything the real app puts in the environment.
    @MainActor
    func previewEnvironment(signedInAs user: User? = PreviewData.aditi) -> some View {
        let container = AppContainer.preview(signedInAs: user)
        return self
            .environment(container)
            .environment(container.appState)
            .environment(container.session)
            .environment(container.serverStatus)
    }
}
