import Foundation
import Observation

/// Reporting and blocking, from any screen, and the list of blocked people
/// in Settings.
@MainActor
@Observable
final class SafetyModel {
    private(set) var blocked: [BlockedPerson] = []
    private(set) var isLoadingBlocked = false
    /// Something that went wrong with the last action, for the screen to show.
    private(set) var problem: String?

    /// Called after a block or unblock, so decks, the map and matches catch up.
    @ObservationIgnored var onBlocksChanged: (() async -> Void)?

    @ObservationIgnored private let api: SafetyAPI

    init(api: SafetyAPI) {
        self.api = api
    }

    /// Forgets the signed-out account's list.
    func reset() {
        blocked = []
        problem = nil
    }

    /// Files the report. True once the server has it.
    func report(_ subject: ReportSubject, reason: ReportReason, details: String) async -> Bool {
        problem = nil
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let (target, id) = subject.request
        do {
            _ = try await api.report(
                ReportRequest(target: target, id: id, reason: reason, details: trimmed.isEmpty ? nil : trimmed)
            )
            return true
        } catch {
            problem = Self.message(for: error)
            return false
        }
    }

    /// Blocks the person. True once the server has it.
    func block(_ subject: BlockSubject) async -> Bool {
        problem = nil
        do {
            try await api.block(subject)
        } catch {
            problem = Self.message(for: error)
            return false
        }
        await onBlocksChanged?()
        return true
    }

    func loadBlocked() async {
        isLoadingBlocked = true
        defer { isLoadingBlocked = false }
        do {
            blocked = try await api.blocked().items
            problem = nil
        } catch let error as APIError where error == .cancelled {
            return
        } catch {
            problem = Self.message(for: error)
        }
    }

    func unblock(_ person: BlockedPerson) async {
        problem = nil
        do {
            try await api.unblock(userID: person.userId)
            blocked.removeAll { $0.id == person.id }
            // Their listings and the chat can come back.
            await onBlocksChanged?()
        } catch {
            problem = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        (error as? APIError)?.userMessage ?? APIError.unreachable.userMessage
    }
}
