import Foundation

enum ListingStatus: String, Codable, CaseIterable {
    case draft
    case active
    case paused
    case filled
    case expired

    var title: String {
        switch self {
        case .draft: return "Draft"
        case .active: return "Live"
        case .paused: return "Paused"
        case .filled: return "Filled"
        case .expired: return "Expired"
        }
    }
}

enum SpaceType: String, Codable, CaseIterable, Identifiable {
    case entireUnit = "entire_unit"
    case privateRoom = "private_room"
    case sharedRoom = "shared_room"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entireUnit: return "Whole place"
        case .privateRoom: return "Private room"
        case .sharedRoom: return "Shared room"
        }
    }

    var detail: String {
        switch self {
        case .entireUnit: return "Nobody else lives there while you're away."
        case .privateRoom: return "Their own bedroom in a shared home."
        case .sharedRoom: return "A bedroom shared with someone who is staying."
        }
    }

    /// True when the renter will live with housemates who are staying. Only
    /// then may a lister set a gender preference.
    var isShared: Bool {
        self != .entireUnit
    }
}

enum Bathroom: String, Codable, CaseIterable, Identifiable {
    case own = "private"
    case shared

    var id: String { rawValue }

    var title: String {
        switch self {
        case .own: return "Private bathroom"
        case .shared: return "Shared bathroom"
        }
    }
}

enum GenderPreference: String, Codable, CaseIterable, Identifiable {
    case anyone = "any"
    case women
    case men

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyone: return "No preference"
        case .women: return "Women"
        case .men: return "Men"
        }
    }
}

/// Who the renter would live with: the housemates who are staying.
enum HouseholdGender: String, Codable, CaseIterable, Identifiable {
    case women
    case men
    case mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .women: return "Women"
        case .men: return "Men"
        case .mixed: return "Mixed"
        }
    }

    /// "Lives with women", for a listing card.
    var livesWith: String {
        switch self {
        case .women: return "Lives with women"
        case .men: return "Lives with men"
        case .mixed: return "Lives with a mixed household"
        }
    }
}

struct ListingPhoto: Codable, Equatable, Identifiable {
    let key: String
    let url: String?

    var id: String { key }
}

/// What renters see about the person offering the place.
struct Lister: Codable, Equatable {
    let firstName: String?
    let photoUrl: String?
    let schoolName: String
    let verified: Bool
}

/// A listing as the server returns it. A draft may be missing most answers.
struct Listing: Codable, Equatable, Identifiable {
    let id: String
    var status: ListingStatus
    let isOwner: Bool
    /// Exact location: only filled in for the owner.
    var address: String?
    var latitude: Double?
    var longitude: Double?
    /// About 150 meters from the real address. What everyone else sees.
    var publicLatitude: Double?
    var publicLongitude: Double?
    var rentCents: Int?
    var depositCents: Int
    var utilitiesIncluded: Bool
    /// Calendar dates as the server sends them, such as "2027-01-14".
    var startDate: String?
    var endDate: String?
    var spaceType: SpaceType?
    var bedrooms: Int?
    var bathroom: Bathroom?
    var furnished: Bool
    var laundry: Bool
    var parking: Bool
    var housematesStaying: Int?
    var housematesNote: String?
    var petsAllowed: Bool?
    var smokingAllowed: Bool?
    /// Null when nobody is staying.
    var householdGender: HouseholdGender?
    var genderPreference: GenderPreference
    var sameSchoolOnly: Bool
    var minStayDays: Int
    var landlordConsent: Bool?
    var photos: [ListingPhoto]
    let lister: Lister
}

struct ListingPage: Decodable, Equatable {
    let items: [Listing]
    let nextCursor: String?
}

/// Every answer in the listing editor, sent whole on each save. Unanswered
/// questions go to the server as an explicit `null`.
struct ListingForm: Encodable, Equatable {
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var rentCents: Int?
    var depositCents: Int = 0
    var utilitiesIncluded = false
    var startDate: String?
    var endDate: String?
    var spaceType: SpaceType?
    var bedrooms: Int?
    var bathroom: Bathroom?
    var furnished = false
    var laundry = false
    var parking = false
    var housematesStaying: Int?
    var housematesNote: String?
    var petsAllowed: Bool?
    var smokingAllowed: Bool?
    var householdGender: HouseholdGender?
    var genderPreference: GenderPreference = .anyone
    var sameSchoolOnly = false
    var minStayDays = 0
    var landlordConsent: Bool?
    var photoKeys: [String] = []

    private enum CodingKeys: String, CodingKey {
        case address, latitude, longitude, rentCents, depositCents, utilitiesIncluded
        case startDate, endDate, spaceType, bedrooms, bathroom, furnished, laundry, parking
        case housematesStaying, housematesNote, petsAllowed, smokingAllowed, householdGender
        case genderPreference, sameSchoolOnly, minStayDays, landlordConsent, photoKeys
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `encode` on an optional writes `null` for nil, which the server reads
        // as "clear this answer". Leaving the key out would mean "keep it".
        try container.encode(address, forKey: .address)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(rentCents, forKey: .rentCents)
        try container.encode(depositCents, forKey: .depositCents)
        try container.encode(utilitiesIncluded, forKey: .utilitiesIncluded)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(spaceType, forKey: .spaceType)
        try container.encode(bedrooms, forKey: .bedrooms)
        try container.encode(bathroom, forKey: .bathroom)
        try container.encode(furnished, forKey: .furnished)
        try container.encode(laundry, forKey: .laundry)
        try container.encode(parking, forKey: .parking)
        try container.encode(housematesStaying, forKey: .housematesStaying)
        try container.encode(housematesNote, forKey: .housematesNote)
        try container.encode(petsAllowed, forKey: .petsAllowed)
        try container.encode(smokingAllowed, forKey: .smokingAllowed)
        try container.encode(householdGender, forKey: .householdGender)
        try container.encode(genderPreference, forKey: .genderPreference)
        try container.encode(sameSchoolOnly, forKey: .sameSchoolOnly)
        try container.encode(minStayDays, forKey: .minStayDays)
        try container.encode(landlordConsent, forKey: .landlordConsent)
        try container.encode(photoKeys, forKey: .photoKeys)
    }
}

extension ListingForm {
    /// The answers already in a saved listing, for editing it.
    init(listing: Listing) {
        self.init(
            address: listing.address,
            latitude: listing.latitude,
            longitude: listing.longitude,
            rentCents: listing.rentCents,
            depositCents: listing.depositCents,
            utilitiesIncluded: listing.utilitiesIncluded,
            startDate: listing.startDate,
            endDate: listing.endDate,
            spaceType: listing.spaceType,
            bedrooms: listing.bedrooms,
            bathroom: listing.bathroom,
            furnished: listing.furnished,
            laundry: listing.laundry,
            parking: listing.parking,
            housematesStaying: listing.housematesStaying,
            housematesNote: listing.housematesNote,
            petsAllowed: listing.petsAllowed,
            smokingAllowed: listing.smokingAllowed,
            householdGender: listing.householdGender,
            genderPreference: listing.genderPreference,
            sameSchoolOnly: listing.sameSchoolOnly,
            minStayDays: listing.minStayDays,
            landlordConsent: listing.landlordConsent,
            photoKeys: listing.photos.map(\.key)
        )
    }
}

// MARK: - Showing a listing

enum CalendarDate {
    /// "2027-01-14", read and written in the phone's own time zone, so the
    /// date picked is the date sent.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else {
            return nil
        }
        return formatter.date(from: string)
    }
}

enum Money {
    /// "$1,200" from 120000 cents.
    static func dollars(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }

    /// Cents from what someone typed: "1200", "1,200", "$1,200.50". Nil if it
    /// is not a number.
    static func cents(from text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else {
            return nil
        }
        return Int((value * 100).rounded())
    }

    /// "1200" or "1200.50" for an edit field, from cents.
    static func editableDollars(_ cents: Int?) -> String {
        guard let cents else {
            return ""
        }
        return cents % 100 == 0 ? String(cents / 100) : String(format: "%.2f", Double(cents) / 100)
    }
}

extension Listing {
    /// "Private room · Shared bathroom · 3 bedrooms"
    var spaceSummary: String {
        var parts: [String] = []
        if let spaceType {
            parts.append(spaceType.title)
        }
        if let bathroom {
            parts.append(bathroom.title)
        }
        if let bedrooms {
            parts.append(bedrooms == 0 ? "Studio" : "\(bedrooms) bedroom\(bedrooms == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// "Jan 14 – Apr 8"
    var dateSummary: String? {
        guard let start = CalendarDate.date(from: startDate),
              let end = CalendarDate.date(from: endDate)
        else {
            return nil
        }
        let style = Date.FormatStyle().month(.abbreviated).day()
        return "\(start.formatted(style)) – \(end.formatted(style))"
    }

    var amenities: [String] {
        var items: [String] = []
        if furnished { items.append("Furnished") }
        if laundry { items.append("In-unit laundry") }
        if parking { items.append("Parking") }
        if utilitiesIncluded { items.append("Utilities included") }
        return items
    }

    /// A short label for the list of the lister's own listings.
    var title: String {
        if let address, !address.isEmpty {
            return address.components(separatedBy: ",").first ?? address
        }
        return spaceType?.title ?? "Untitled listing"
    }
}
