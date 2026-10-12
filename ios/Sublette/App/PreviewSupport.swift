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
