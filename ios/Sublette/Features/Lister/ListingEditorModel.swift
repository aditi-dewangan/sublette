import Foundation
import Observation

/// A photo in the editor: already uploaded, with its key, and something to show.
struct EditorPhoto: Identifiable, Equatable {
    let key: String
    /// The address of a photo saved before, when editing.
    let remoteURL: String?
    /// The picked photo itself, shown until the listing is saved.
    let localJPEG: Data?

    var id: String { key }
}

/// Creating or editing a listing, one step per screen.
@MainActor
@Observable
final class ListingEditorModel {
    enum Step: Int, CaseIterable, Identifiable {
        case photos
        case address
        case rentAndDates
        case space
        case household
        case whoCanTakeIt
        case landlordConsent
        case preview

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .photos: return "Photos"
            case .address: return "Address"
            case .rentAndDates: return "Rent and dates"
            case .space: return "The space"
            case .household: return "The household"
            case .whoCanTakeIt: return "Who can take it"
            case .landlordConsent: return "Landlord consent"
            case .preview: return "Preview"
            }
        }
    }

    static let minPhotos = 4
    static let maxPhotos = 12
    static let noteLimit = 140

    // MARK: Answers

    var photos: [EditorPhoto] = []
    var address = ""
    /// The point the lister confirmed on the map.
    private(set) var confirmedCoordinate: Coordinate?
    /// The point the last lookup found, waiting for the lister to confirm it.
    private(set) var candidate: LocatedAddress?
    var rentText = ""
    var depositText = ""
    var utilitiesIncluded = false
    var startDate: Date
    var endDate: Date
    /// A gender preference is only sent when this is a shared home (see `form`).
    var spaceType: SpaceType?
    var bedrooms = 1
    var bathroom: Bathroom?
    var furnished = false
    var laundry = false
    var parking = false
    var housematesStaying = 0
    var housematesNote = ""
    var petsAllowed: Bool?
    var smokingAllowed: Bool?
    /// Only sent while someone is staying (see `form`).
    var householdGender: HouseholdGender?
    /// How the housemates staying live (optional).
    var homeLife = HomeLife()
    var sameSchoolOnly = false
    var minStayWeeks = 0
    var genderPreference: GenderPreference = .anyone
    var landlordConsent: Bool?

    // MARK: Progress

    var step: Step = .photos
    private(set) var isSaving = false
    private(set) var isLocating = false
    private(set) var uploadingPhotos = 0
    private(set) var photoMessage: String?
    private(set) var addressMessage: String?
    private(set) var errorMessage: String?
    /// Messages keyed by the server's field names, such as `rent_cents`.
    private(set) var fieldErrors: [String: String] = [:]

    private(set) var listing: Listing?

    private let api: ListingsAPI
    private let uploader: PhotoUploading
    private let locator: AddressLocating
    private let schoolName: String

    init(
        listing: Listing?,
        schoolName: String,
        api: ListingsAPI,
        uploader: PhotoUploading,
        locator: AddressLocating,
        today: Date = Date()
    ) {
        self.schoolName = schoolName
        self.api = api
        self.uploader = uploader
        self.locator = locator
        self.listing = listing

        let calendar = Calendar.current
        let defaultStart = calendar.date(byAdding: .day, value: 14, to: calendar.startOfDay(for: today)) ?? today
        let start = CalendarDate.date(from: listing?.startDate) ?? defaultStart
        self.startDate = start
        self.endDate = CalendarDate.date(from: listing?.endDate)
            ?? calendar.date(byAdding: .day, value: 84, to: start) ?? start

        guard let listing else {
            return
        }
        photos = listing.photos.map { EditorPhoto(key: $0.key, remoteURL: $0.url, localJPEG: nil) }
        address = listing.address ?? ""
        if let latitude = listing.latitude, let longitude = listing.longitude {
            confirmedCoordinate = Coordinate(latitude: latitude, longitude: longitude)
        }
        rentText = Money.editableDollars(listing.rentCents)
        depositText = listing.depositCents == 0 ? "" : Money.editableDollars(listing.depositCents)
        utilitiesIncluded = listing.utilitiesIncluded
        spaceType = listing.spaceType
        bedrooms = listing.bedrooms ?? 1
        bathroom = listing.bathroom
        furnished = listing.furnished
        laundry = listing.laundry
        parking = listing.parking
        housematesStaying = listing.housematesStaying ?? 0
        housematesNote = listing.housematesNote ?? ""
        petsAllowed = listing.petsAllowed
        smokingAllowed = listing.smokingAllowed
        householdGender = listing.householdGender
        homeLife = HomeLife(listing: listing)
        sameSchoolOnly = listing.sameSchoolOnly
        minStayWeeks = listing.minStayDays / 7
        genderPreference = listing.genderPreference
        landlordConsent = listing.landlordConsent
    }

    var isEditing: Bool {
        listing != nil
    }

    /// Live and paused listings are saved as they are; drafts are published at the end.
    var isPublished: Bool {
        listing?.status == .active || listing?.status == .paused
    }

    var schoolOnlyTitle: String {
        "Only students from \(schoolName)"
    }

    // MARK: - The answers as the server wants them

    var form: ListingForm {
        let note = housematesNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return ListingForm(
            address: trimmedAddress.isEmpty ? nil : trimmedAddress,
            latitude: confirmedCoordinate?.latitude,
            longitude: confirmedCoordinate?.longitude,
            rentCents: Money.cents(from: rentText),
            depositCents: Money.cents(from: depositText) ?? 0,
            utilitiesIncluded: utilitiesIncluded,
            startDate: CalendarDate.string(from: startDate),
            endDate: CalendarDate.string(from: endDate),
            spaceType: spaceType,
            bedrooms: bedrooms,
            bathroom: bathroom,
            furnished: furnished,
            laundry: laundry,
            parking: parking,
            housematesStaying: housematesStaying,
            housematesNote: note.isEmpty ? nil : note,
            petsAllowed: petsAllowed,
            smokingAllowed: smokingAllowed,
            householdGender: housematesStaying > 0 ? householdGender : nil,
            genderPreference: spaceType?.isShared == true ? genderPreference : .anyone,
            sameSchoolOnly: sameSchoolOnly,
            minStayDays: minStayWeeks * 7,
            landlordConsent: landlordConsent,
            photoKeys: photos.map(\.key),
            homeLife: housematesStaying > 0 && spaceType != .entireUnit ? homeLife : HomeLife()
        )
    }

    var stayDays: Int {
        Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
    }

    // MARK: - Checking each step before moving on

    /// Problems on one step, keyed by the server's field names. The server
    /// checks the same rules; this only gives faster answers.
    func problems(on step: Step) -> [String: String] {
        var found: [String: String] = [:]
        switch step {
        case .photos:
            if photos.count < Self.minPhotos {
                found["photo_keys"] = "Add at least \(Self.minPhotos) photos."
            }
        case .address:
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found["address"] = "Enter the address."
            } else if confirmedCoordinate == nil {
                found["latitude"] = "Confirm the address on the map."
            }
        case .rentAndDates:
            if let rent = Money.cents(from: rentText) {
                if rent <= 0 {
                    found["rent_cents"] = "Enter the monthly rent."
                }
            } else {
                found["rent_cents"] = "Enter the monthly rent."
            }
            if !depositText.trimmingCharacters(in: .whitespaces).isEmpty,
               Money.cents(from: depositText) == nil {
                found["deposit_cents"] = "Enter the deposit as a number, or leave it empty."
            }
            if endDate <= startDate {
                found["end_date"] = "The end date must be after the start date."
            }
        case .space:
            if spaceType == nil {
                found["space_type"] = "Choose the type of space."
            }
            if bathroom == nil {
                found["bathroom"] = "Choose a private or shared bathroom."
            }
        case .household:
            if housematesStaying > 0, householdGender == nil {
                found["household_gender"] = "Say who the housemates staying are."
            }
            if petsAllowed == nil {
                found["pets_allowed"] = "Say whether pets are welcome."
            }
            if smokingAllowed == nil {
                found["smoking_allowed"] = "Say whether smokers are welcome."
            }
            if housematesNote.count > Self.noteLimit {
                found["housemates_note"] = "Keep this to \(Self.noteLimit) characters or fewer."
            }
        case .whoCanTakeIt:
            if minStayWeeks * 7 > stayDays {
                found["min_stay_days"] = "The minimum stay is longer than the dates you're offering."
            }
        case .landlordConsent:
            if landlordConsent == nil {
                found["landlord_consent"] = "Say whether your landlord has approved subletting."
            }
        case .preview:
            for earlier in Step.allCases where earlier != .preview {
                found.merge(problems(on: earlier)) { first, _ in first }
            }
        }
        return found
    }

    /// Moves to the next step if this one is complete; shows its problems if not.
    func next() {
        let found = problems(on: step)
        fieldErrors = found
        guard found.isEmpty, let following = Step(rawValue: step.rawValue + 1) else {
            return
        }
        errorMessage = nil
        step = following
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else {
            return
        }
        fieldErrors = [:]
        step = previous
    }

    nonisolated static func step(forField field: String) -> Step {
        switch field {
        case "photo_keys": return .photos
        case "address", "latitude", "longitude": return .address
        case "rent_cents", "deposit_cents", "utilities_included", "start_date", "end_date":
            return .rentAndDates
        case "space_type", "bedrooms", "bathroom", "furnished", "laundry", "parking":
            return .space
        case "housemates_staying", "housemates_note", "household_gender", "pets_allowed", "smoking_allowed":
            return .household
        case "gender_preference", "same_school_only", "min_stay_days":
            return .whoCanTakeIt
        case "landlord_consent":
            return .landlordConsent
        default:
            return .preview
        }
    }

    // MARK: - Photos

    var canAddPhotos: Bool {
        photos.count + uploadingPhotos < Self.maxPhotos
    }

    /// Uploads picked photos one at a time. A photo that fails is skipped and
    /// reported; the others still go up.
    func addPhotos(_ jpegs: [Data]) async {
        photoMessage = nil
        var failures = 0
        for jpeg in jpegs where canAddPhotos {
            uploadingPhotos += 1
            do {
                let key = try await uploader.uploadListingPhoto(jpeg)
                photos.append(EditorPhoto(key: key, remoteURL: nil, localJPEG: jpeg))
            } catch {
                failures += 1
                if let error = error as? APIError, case .server(_, "uploads_unavailable", let message, _) = error {
                    photoMessage = message
                }
            }
            uploadingPhotos -= 1
        }
        if failures > 0, photoMessage == nil {
            photoMessage = failures == 1
                ? "One photo couldn't be uploaded. Try adding it again."
                : "\(failures) photos couldn't be uploaded. Try adding them again."
        }
        if photos.count >= Self.minPhotos {
            fieldErrors["photo_keys"] = nil
        }
    }

    func photoCouldNotBeRead() {
        photoMessage = "A photo couldn't be read. Try a different one."
    }

    /// Reorders photos the way a SwiftUI list's drag-to-move reports it.
    func movePhotos(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { photos[$0] }
        var remaining = photos.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        photos = remaining
    }

    func removePhotos(at offsets: IndexSet) {
        photos = photos.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    // MARK: - Address

    /// Looks the typed address up, to show on the map for confirmation.
    func locateAddress() async {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !isLocating else {
            addressMessage = typed.isEmpty ? "Enter the address first." : addressMessage
            return
        }
        isLocating = true
        addressMessage = nil
        candidate = nil
        defer { isLocating = false }
        do {
            candidate = try await locator.locate(typed)
        } catch AddressLookupError.notFound {
            addressMessage = "Couldn't find that address. Check the street and city."
        } catch {
            addressMessage = "Couldn't look up the address right now. Check your connection and try again."
        }
    }

    func confirmCandidate() {
        guard let candidate else {
            return
        }
        confirmedCoordinate = candidate.coordinate
        fieldErrors["latitude"] = nil
        fieldErrors["address"] = nil
    }

    /// Typing a new address means the old pin no longer applies.
    func addressEdited() {
        if candidate != nil || confirmedCoordinate != nil {
            candidate = nil
            confirmedCoordinate = nil
        }
    }

    // MARK: - Saving

    /// Saves the answers without publishing. Returns the saved listing.
    @discardableResult
    func saveDraft() async -> Listing? {
        await save(publish: false)
    }

    /// Saves, then publishes a draft. Returns the listing renters will see.
    @discardableResult
    func publish() async -> Listing? {
        await save(publish: true)
    }

    private func save(publish: Bool) async -> Listing? {
        guard !isSaving else {
            return nil
        }
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { isSaving = false }
        do {
            var saved: Listing
            if let listing {
                saved = try await api.update(id: listing.id, form)
            } else {
                saved = try await api.create(form)
            }
            // From here on, saving again updates this listing instead of making another.
            listing = saved
            if publish, saved.status == .draft {
                saved = try await api.setStatus(id: saved.id, .active)
                listing = saved
            }
            return saved
        } catch let error as APIError {
            if case .cancelled = error {
                return nil
            }
            fieldErrors = error.fieldMessages
            errorMessage = error.userMessage
            if let first = Step.allCases.first(where: { step in
                fieldErrors.keys.contains { Self.step(forField: $0) == step }
            }) {
                step = first
            }
            return nil
        } catch {
            errorMessage = APIError.unreachable.userMessage
            return nil
        }
    }

    /// What the preview shows: the answers so far, laid out as renters see them.
    var previewListing: Listing {
        let answers = form
        return Listing(
            id: listing?.id ?? "preview",
            status: listing?.status ?? .draft,
            isOwner: false,
            address: nil,
            latitude: nil,
            longitude: nil,
            publicLatitude: nil,
            publicLongitude: nil,
            rentCents: answers.rentCents,
            depositCents: answers.depositCents,
            utilitiesIncluded: answers.utilitiesIncluded,
            startDate: answers.startDate,
            endDate: answers.endDate,
            spaceType: answers.spaceType,
            bedrooms: answers.bedrooms,
            bathroom: answers.bathroom,
            furnished: answers.furnished,
            laundry: answers.laundry,
            parking: answers.parking,
            housematesStaying: answers.housematesStaying,
            housematesNote: answers.housematesNote,
            petsAllowed: answers.petsAllowed,
            smokingAllowed: answers.smokingAllowed,
            householdGender: answers.householdGender,
            genderPreference: answers.genderPreference,
            sameSchoolOnly: answers.sameSchoolOnly,
            minStayDays: answers.minStayDays,
            landlordConsent: answers.landlordConsent,
            photos: photos.map { ListingPhoto(key: $0.key, url: $0.remoteURL) },
            lister: listing?.lister ?? Lister(firstName: nil, photoUrl: nil, schoolName: schoolName, verified: true)
        )
    }
}
