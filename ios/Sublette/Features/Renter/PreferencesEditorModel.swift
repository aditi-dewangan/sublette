import Foundation
import Observation

/// Who the renter wants to live with, as the app asks it.
enum LiveWithChoice: String, CaseIterable, Identifiable {
    case women
    case men
    case noPreference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .women: return "Women"
        case .men: return "Men"
        case .noPreference: return "No preference"
        }
    }

    var gender: HousemateGender? {
        switch self {
        case .women: return .women
        case .men: return .men
        case .noPreference: return nil
        }
    }
}

/// The renter's preference flow: dates, budget, space type, the rest of the
/// preferences, then the area on the map. Saved in one request at the end.
@MainActor
@Observable
final class PreferencesEditorModel {
    enum Step: Int, CaseIterable, Identifiable {
        case dates
        case budget
        case spaceType
        case preferences
        case area

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .dates: return "Dates"
            case .budget: return "Budget"
            case .spaceType: return "Type of space"
            case .preferences: return "What matters"
            case .area: return "Where"
            }
        }
    }

    static let flexibilityChoices = [0, 3, 7, 14, 30]
    static let metersPerMile = 1_609.344

    // MARK: Answers

    var startDate: Date
    var endDate: Date
    var flexibilityDays = 0
    var budgetText = ""
    var spaceTypes: Set<SpaceType> = []
    /// Must or nice. Ignored when every type is chosen.
    var spaceTypeImportance: Importance = .must
    var flagImportance: [PreferenceField: Importance] = [:]
    var housemateCount = 2
    var housemateCountImportance: Importance = .off
    var liveWith: LiveWithChoice = .noPreference
    /// Must or nice, once women or men is chosen.
    var liveWithImportance: Importance = .must
    /// The middle of the map. Nil until the map or the campus shortcut sets it.
    var center: Coordinate?
    var radiusM = SearchPin.defaultRadiusM

    // MARK: Progress

    var step: Step
    private(set) var isSaving = false
    private(set) var isLocatingCampus = false
    private(set) var campusMessage: String?
    /// Goes up each time the app, not the renter, moves the map, so the map follows.
    private(set) var recenterCount = 0
    private(set) var errorMessage: String?
    /// Messages keyed by the server's field names, such as `max_rent_cents`.
    private(set) var fieldErrors: [String: String] = [:]

    let schoolName: String
    private let api: RenterAPI
    private let campusLocator: CampusLocating
    private let existing: RenterProfile?

    init(
        profile: RenterProfile?,
        schoolName: String,
        api: RenterAPI,
        campusLocator: CampusLocating,
        startAt step: Step = .dates,
        today: Date = Date()
    ) {
        self.schoolName = schoolName
        self.api = api
        self.campusLocator = campusLocator
        self.existing = profile
        self.step = step

        let calendar = Calendar.current
        let defaultStart = calendar.date(byAdding: .day, value: 30, to: calendar.startOfDay(for: today)) ?? today
        let start = CalendarDate.date(from: profile?.startDate) ?? defaultStart
        startDate = start
        endDate = CalendarDate.date(from: profile?.endDate)
            ?? calendar.date(byAdding: .day, value: 90, to: start) ?? start

        guard let profile else {
            return
        }
        flexibilityDays = profile.flexibilityDays
        budgetText = Money.editableDollars(profile.maxRentCents)
        if let pin = profile.pin {
            center = pin.coordinate
            radiusM = pin.radiusM
        }
        for preference in profile.preferences {
            switch preference.value {
            case .spaceTypes(let types):
                spaceTypes = Set(types)
                spaceTypeImportance = preference.importance == .nice ? .nice : .must
            case .yes:
                flagImportance[preference.field] = preference.importance
            case .count(let count):
                housemateCount = count
                housemateCountImportance = preference.importance
            case .gender(let gender):
                if preference.importance != .off {
                    liveWith = gender == .women ? .women : .men
                    liveWithImportance = preference.importance
                }
            }
        }
    }

    var isEditing: Bool {
        existing?.updatedAt != nil
    }

    func importance(of field: PreferenceField) -> Importance {
        flagImportance[field] ?? .off
    }

    func setImportance(_ importance: Importance, of field: PreferenceField) {
        flagImportance[field] = importance
    }

    // MARK: - The answers as the server wants them

    var preferences: [Preference] {
        var list: [Preference] = []
        // Same order as the server's list, so a save and a reload match.
        if !spaceTypes.isEmpty {
            let ordered = SpaceType.allCases.filter { spaceTypes.contains($0) }
            let everything = ordered.count == SpaceType.allCases.count
            list.append(Preference(
                field: .spaceType,
                value: .spaceTypes(ordered),
                importance: everything ? .off : spaceTypeImportance
            ))
        }
        for field in PreferenceField.flags {
            list.append(Preference(field: field, value: .yes, importance: importance(of: field)))
        }
        list.append(Preference(field: .housemateCount, value: .count(housemateCount), importance: housemateCountImportance))
        if let gender = liveWith.gender {
            list.append(Preference(field: .housemateGender, value: .gender(gender), importance: liveWithImportance))
        }
        return list
    }

    var form: RenterProfileForm {
        RenterProfileForm(
            startDate: CalendarDate.string(from: startDate),
            endDate: CalendarDate.string(from: endDate),
            flexibilityDays: flexibilityDays,
            maxRentCents: Money.cents(from: budgetText),
            preferences: preferences,
            pin: center.map { SearchPin(latitude: $0.latitude, longitude: $0.longitude, radiusM: radiusM) }
        )
    }

    var radiusMiles: Double {
        Double(radiusM) / Self.metersPerMile
    }

    /// "3.0 miles"
    var radiusText: String {
        let miles = radiusMiles
        return String(format: miles < 10 ? "%.1f miles" : "%.0f miles", miles)
    }

    // MARK: - Checking each step before moving on

    func problems(on step: Step) -> [String: String] {
        var found: [String: String] = [:]
        switch step {
        case .dates:
            if endDate <= startDate {
                found["end_date"] = "The end date must be after the start date."
            }
        case .budget:
            if (Money.cents(from: budgetText) ?? 0) <= 0 {
                found["max_rent_cents"] = "Enter the most you'd pay each month."
            }
        case .spaceType:
            if spaceTypes.isEmpty {
                found["space_type"] = "Choose at least one."
            }
        case .preferences:
            break
        case .area:
            if center == nil {
                found["pin"] = "Move the map to where you want to live."
            }
        }
        return found
    }

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

    nonisolated static func step(forField field: String, preferences: [Preference]) -> Step {
        switch field {
        case "start_date", "end_date", "flexibility_days": return .dates
        case "max_rent_cents": return .budget
        case "pin": return .area
        default:
            // "preferences.3.value" names an item in the list that was sent.
            let parts = field.split(separator: ".")
            if parts.first == "pin" {
                return .area
            }
            if parts.count >= 2, parts[0] == "preferences", let index = Int(parts[1]),
               preferences.indices.contains(index) {
                return preferences[index].field == .spaceType ? .spaceType : .preferences
            }
            return .preferences
        }
    }

    // MARK: - The map

    /// The renter moved the map.
    func mapMoved(to coordinate: Coordinate) {
        center = coordinate
        fieldErrors["pin"] = nil
    }

    /// Centers the map on the renter's campus, found by the school's name.
    func useMyCampus() async {
        guard !isLocatingCampus else {
            return
        }
        isLocatingCampus = true
        campusMessage = nil
        defer { isLocatingCampus = false }
        do {
            center = try await campusLocator.locateCampus(named: schoolName)
            recenterCount += 1
            fieldErrors["pin"] = nil
        } catch AddressLookupError.notFound {
            campusMessage = "Couldn't find \(schoolName) on the map. Move the map to your campus instead."
        } catch {
            campusMessage = "Maps can't be reached right now. Move the map yourself, or try again."
        }
    }

    // MARK: - Saving

    /// Saves everything. Returns the saved profile, or nil and shows why not.
    func save() async -> RenterProfile? {
        var found: [String: String] = [:]
        for each in Step.allCases {
            found.merge(problems(on: each)) { first, _ in first }
        }
        if let first = found.keys.map({ Self.step(forField: $0, preferences: preferences) }).min(by: { $0.rawValue < $1.rawValue }) {
            fieldErrors = found
            step = first
            return nil
        }
        guard !isSaving else {
            return nil
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let sent = form
        do {
            return try await api.saveRenterProfile(sent)
        } catch let error as APIError {
            let fields = error.fieldMessages
            if !fields.isEmpty {
                fieldErrors = fields
                if let first = fields.keys.map({ Self.step(forField: $0, preferences: sent.preferences) })
                    .min(by: { $0.rawValue < $1.rawValue }) {
                    step = first
                }
            }
            errorMessage = error.userMessage
            return nil
        } catch {
            errorMessage = APIError.unreachable.userMessage
            return nil
        }
    }
}
