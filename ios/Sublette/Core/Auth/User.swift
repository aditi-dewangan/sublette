import Foundation

struct School: Codable, Equatable {
    let id: String
    /// The school's name, or its email domain while nobody has named it yet.
    let name: String
}

enum Year: String, Codable, CaseIterable, Identifiable {
    case freshman
    case sophomore
    case junior
    case senior
    case graduate
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freshman: return "Freshman"
        case .sophomore: return "Sophomore"
        case .junior: return "Junior"
        case .senior: return "Senior"
        case .graduate: return "Graduate student"
        case .other: return "Other"
        }
    }
}

/// How often alerts about listings come.
enum AlertFrequency: String, Codable, CaseIterable, Identifiable {
    case instant
    case daily
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant: return "As they happen"
        case .daily: return "One a day"
        case .off: return "Off"
        }
    }
}

enum Gender: String, Codable, CaseIterable, Identifiable {
    case woman
    case man
    case nonbinary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .woman: return "Woman"
        case .man: return "Man"
        case .nonbinary: return "Non-binary"
        }
    }
}

/// The signed-in student's own account, as `GET /v1/me` returns it.
///
/// The server sends snake_case (`first_name`, `photo_url`). `APIClient` converts
/// that to camelCase, which is why this says `photoUrl` and not `photoURL`.
struct User: Codable, Equatable, Identifiable {
    let id: String
    let email: String
    let school: School
    let verified: Bool
    var firstName: String?
    var year: Year?
    var program: String?
    var bio: String?
    var photoUrl: String?
    var gender: Gender?
    var smokes: Bool?
    var hasPets: Bool?
    /// True once first name, year, program, smokes and pets are all answered.
    var profileComplete: Bool
    /// Sublets finished through Sublette. Optional so a profile saved on the
    /// phone by an older version still loads.
    var completedSublets: Int?
    /// The current terms of service and privacy policy, and whether this
    /// account accepted them. Optional for the same reason.
    var termsVersion: String?
    var termsAccepted: Bool?
    /// This account's code to give friends, and whether it used someone's.
    var referralCode: String?
    var referred: Bool?
    /// How often alerts come. Optional for profiles saved by an older version.
    var alertFrequency: AlertFrequency?

    /// True when the server says the current terms still need accepting.
    var needsToAcceptTerms: Bool { termsAccepted == false }
}
