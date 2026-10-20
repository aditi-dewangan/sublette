import Foundation
import SwiftData

/// One saved answer from the server, kept on the phone so screens can show
/// it offline. The value is JSON, so any `Codable` type fits.
@Model
final class CachedPayload {
    /// "<account id>:<what>", such as "user-1:deck" or "user-1:chat:match-9".
    @Attribute(.unique) var key: String
    var data: Data
    var savedAt: Date

    init(key: String, data: Data, savedAt: Date) {
        self.key = key
        self.data = data
        self.savedAt = savedAt
    }
}

/// What screens keep for offline use: the next deck cards, matches, saved
/// listings, chat history, and messages waiting to be sent.
@MainActor
protocol OfflineStoring: AnyObject {
    func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value?
    func save<Value: Encodable>(_ value: Value, key: String)
    func remove(key: String)
    /// Forgets everything kept for one account, as at sign-out.
    func removeAll(accountID: String)
}

/// The cache in SwiftData, on disk in the app's own container. Nothing in it
/// leaves the phone. A cache that can't be opened or read is simply empty:
/// the app then works online only, as before.
@MainActor
final class OfflineCache: OfflineStoring {
    private let context: ModelContext?
    // Plain JSON, not the server's snake_case: a round trip must give back
    // exactly what was saved (`matchID` would come back as `matchId`).
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: () -> Date

    init(inMemory: Bool = false, now: @escaping () -> Date = { Date() }) {
        self.now = now
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            // A fresh install has no Application Support folder yet.
            let folder = URL.applicationSupportDirectory
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: folder.appending(path: "offline-cache.store"))
        }
        if let container = try? ModelContainer(for: CachedPayload.self, configurations: configuration) {
            context = ModelContext(container)
        } else {
            context = nil
        }
    }

    func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let row = find(key) else {
            return nil
        }
        // An old shape the app no longer reads is as good as nothing.
        return try? decoder.decode(type, from: row.data)
    }

    func save<Value: Encodable>(_ value: Value, key: String) {
        guard let context, let data = try? encoder.encode(value) else {
            return
        }
        if let row = find(key) {
            row.data = data
            row.savedAt = now()
        } else {
            context.insert(CachedPayload(key: key, data: data, savedAt: now()))
        }
        try? context.save()
    }

    func remove(key: String) {
        guard let context, let row = find(key) else {
            return
        }
        context.delete(row)
        try? context.save()
    }

    func removeAll(accountID: String) {
        guard let context else {
            return
        }
        let prefix = "\(accountID):"
        let rows = (try? context.fetch(FetchDescriptor<CachedPayload>(
            predicate: #Predicate { $0.key.starts(with: prefix) }
        ))) ?? []
        rows.forEach(context.delete)
        try? context.save()
    }

    private func find(_ key: String) -> CachedPayload? {
        guard let context else {
            return nil
        }
        var descriptor = FetchDescriptor<CachedPayload>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// The cache keys, in one place.
enum CacheKey {
    static func deck(_ account: String) -> String { "\(account):deck" }
    static func matches(_ account: String) -> String { "\(account):matches" }
    static func saved(_ account: String) -> String { "\(account):saved" }
    static func chat(_ account: String, match: String) -> String { "\(account):chat:\(match)" }
    static func outbox(_ account: String) -> String { "\(account):outbox" }
}
