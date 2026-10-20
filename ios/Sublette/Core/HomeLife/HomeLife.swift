import Foundation

/// The five optional lifestyle questions (issue #20), asked of a renter about
/// themselves and of a lister about the housemates staying. The server turns
/// matching answers into a few points and "You'd fit in: …" on the card.
enum SleepSchedule: String, Codable, CaseIterable, Identifiable {
    case early, late, varies
    var id: String { rawValue }
    var title: String {
        switch self {
        case .early: return "Early bird"
        case .late: return "Night owl"
        case .varies: return "It varies"
        }
    }
}

enum Tidiness: String, Codable, CaseIterable, Identifiable {
    case veryTidy = "very_tidy", tidy, relaxed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .veryTidy: return "Very tidy"
        case .tidy: return "Tidy"
        case .relaxed: return "Relaxed"
        }
    }
}

enum HowOften: String, Codable, CaseIterable, Identifiable {
    case rarely, sometimes, often
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rarely: return "Rarely"
        case .sometimes: return "Sometimes"
        case .often: return "Often"
        }
    }
}

enum HomeVibe: String, Codable, CaseIterable, Identifiable {
    case quiet, social, either
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quiet: return "Quiet"
        case .social: return "Social"
        case .either: return "Either"
        }
    }
}

/// All five answers together, for the editors. On the wire they are five
/// separate fields of the user or the listing.
struct HomeLife: Equatable {
    var sleepSchedule: SleepSchedule?
    var tidiness: Tidiness?
    var guests: HowOften?
    var homeDaytime: HowOften?
    var homeVibe: HomeVibe?

    var answered: Int {
        [sleepSchedule != nil, tidiness != nil, guests != nil, homeDaytime != nil, homeVibe != nil]
            .filter { $0 }.count
    }

    init(
        sleepSchedule: SleepSchedule? = nil,
        tidiness: Tidiness? = nil,
        guests: HowOften? = nil,
        homeDaytime: HowOften? = nil,
        homeVibe: HomeVibe? = nil
    ) {
        self.sleepSchedule = sleepSchedule
        self.tidiness = tidiness
        self.guests = guests
        self.homeDaytime = homeDaytime
        self.homeVibe = homeVibe
    }

    init(user: User) {
        self.init(
            sleepSchedule: user.sleepSchedule, tidiness: user.tidiness, guests: user.guests,
            homeDaytime: user.homeDaytime, homeVibe: user.homeVibe
        )
    }

    init(listing: Listing) {
        self.init(
            sleepSchedule: listing.sleepSchedule, tidiness: listing.tidiness, guests: listing.guests,
            homeDaytime: listing.homeDaytime, homeVibe: listing.homeVibe
        )
    }

    enum Keys: String, CodingKey {
        case sleepSchedule, tidiness, guests, homeDaytime, homeVibe
    }

    /// Writes all five, `null` for unanswered (which clears them on the server).
    func encode<Key: CodingKey>(into container: inout KeyedEncodingContainer<Key>, keys: (Keys) -> Key) throws {
        try container.encode(sleepSchedule, forKey: keys(.sleepSchedule))
        try container.encode(tidiness, forKey: keys(.tidiness))
        try container.encode(guests, forKey: keys(.guests))
        try container.encode(homeDaytime, forKey: keys(.homeDaytime))
        try container.encode(homeVibe, forKey: keys(.homeVibe))
    }
}
