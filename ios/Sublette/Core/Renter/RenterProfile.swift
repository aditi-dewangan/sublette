import Foundation

/// How much a renter cares about one preference.
enum Importance: String, Codable, CaseIterable, Identifiable {
    /// A listing without it is never shown.
    case must
    /// A listing with it ranks higher.
    case nice
    /// Ignored.
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .must: return "Must have"
        case .nice: return "Nice to have"
        case .off: return "Off"
        }
    }
}

/// Who a renter wants to live with. "No preference" is importance `.off`.
enum HousemateGender: String, Codable, CaseIterable, Identifiable {
    case women
    case men

    var id: String { rawValue }

    var title: String {
        switch self {
        case .women: return "Women"
        case .men: return "Men"
        }
    }
}

/// The preferences the server knows, in the order the app lists them.
enum PreferenceField: String, Codable, CaseIterable, Identifiable {
    case spaceType = "space_type"
    case privateBathroom = "private_bathroom"
    case furnished
    case laundry
    case parking
    case petFree = "pet_free"
    case smokeFree = "smoke_free"
    case housemateCount = "housemate_count"
    case housemateGender = "housemate_gender"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spaceType: return "Type of space"
        case .privateBathroom: return "Private bathroom"
        case .furnished: return "Furnished"
        case .laundry: return "In-unit laundry"
        case .parking: return "Parking"
        case .petFree: return "Pet-free home"
        case .smokeFree: return "Smoke-free home"
        case .housemateCount: return "Number of housemates"
        case .housemateGender: return "Who you live with"
        }
    }

    /// The yes-or-no preferences: their value is always "yes, I want this".
    static let flags: [PreferenceField] = [
        .privateBathroom, .furnished, .laundry, .parking, .petFree, .smokeFree,
    ]
}

/// A preference's value. Which case is used depends on the field.
enum PreferenceValue: Equatable {
    case spaceTypes([SpaceType])
    case yes
    case count(Int)
    case gender(HousemateGender)
}

/// One preference, as the server stores it: `{field, value, importance}`.
struct Preference: Codable, Equatable {
    var field: PreferenceField
    var value: PreferenceValue
    var importance: Importance

    private enum CodingKeys: String, CodingKey {
        case field, value, importance
    }

    init(field: PreferenceField, value: PreferenceValue, importance: Importance) {
        self.field = field
        self.value = value
        self.importance = importance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decode(PreferenceField.self, forKey: .field)
        importance = try container.decode(Importance.self, forKey: .importance)
        // The field says what type the value is, so `true` is never read as 1.
        switch field {
        case .spaceType:
            value = .spaceTypes(try container.decode([SpaceType].self, forKey: .value))
        case .housemateCount:
            value = .count(try container.decode(Int.self, forKey: .value))
        case .housemateGender:
            value = .gender(try container.decode(HousemateGender.self, forKey: .value))
        default:
            guard try container.decode(Bool.self, forKey: .value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "A flag preference is always true."
                )
            }
            value = .yes
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(field, forKey: .field)
        try container.encode(importance, forKey: .importance)
        switch value {
        case .spaceTypes(let types): try container.encode(types, forKey: .value)
        case .yes: try container.encode(true, forKey: .value)
        case .count(let count): try container.encode(count, forKey: .value)
        case .gender(let gender): try container.encode(gender, forKey: .value)
        }
    }
}

/// The middle of the area a renter wants to live in, and how far around it.
/// Private: the server returns it only to its owner.
struct SearchPin: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var radiusM: Int

    static let minRadiusM = 500
    static let maxRadiusM = 50_000
    static let defaultRadiusM = 4_828 // 3 miles

    var coordinate: Coordinate {
        Coordinate(latitude: latitude, longitude: longitude)
    }
}

/// What a renter is looking for, as the server returns it.
struct RenterProfile: Codable, Equatable {
    var startDate: String?
    var endDate: String?
    var flexibilityDays: Int
    var maxRentCents: Int?
    var preferences: [Preference]
    var pin: SearchPin?
    /// Dates, budget and pin are all set.
    var complete: Bool
    var updatedAt: Date?

    static let empty = RenterProfile(
        startDate: nil, endDate: nil, flexibilityDays: 0, maxRentCents: nil,
        preferences: [], pin: nil, complete: false, updatedAt: nil
    )

    func preference(_ field: PreferenceField) -> Preference? {
        preferences.first { $0.field == field }
    }

    var form: RenterProfileForm {
        RenterProfileForm(
            startDate: startDate,
            endDate: endDate,
            flexibilityDays: flexibilityDays,
            maxRentCents: maxRentCents,
            preferences: preferences,
            pin: pin
        )
    }

    /// The must-haves, by name, for a summary.
    var mustHaves: [String] {
        preferences.filter { $0.importance == .must }.map(\.summary)
    }
}

/// The whole renter profile, sent on every save. The server replaces what it had.
struct RenterProfileForm: Encodable, Equatable {
    var startDate: String?
    var endDate: String?
    var flexibilityDays: Int
    var maxRentCents: Int?
    var preferences: [Preference]
    var pin: SearchPin?
}

extension Preference {
    /// "Furnished", "Private room or whole place", "At most 2 housemates", "Live with women".
    var summary: String {
        switch value {
        case .spaceTypes(let types):
            return types.map(\.title).joined(separator: " or ")
        case .yes:
            return field.title
        case .count(let count):
            return count == 0 ? "No housemates" : "At most \(count) housemate\(count == 1 ? "" : "s")"
        case .gender(let gender):
            return "Live with \(gender.title.lowercased())"
        }
    }
}
