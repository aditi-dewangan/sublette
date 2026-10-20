import Foundation
import MetricKit

/// Reports app opens and feature use to the server, and sends crash reports.
/// Never in the way: everything is sent in the background, failures are
/// dropped (crash reports are kept and tried again at the next open).
@MainActor
final class AnalyticsModel {
    private let api: ReleaseAPI
    private let preferences: Preferences
    private let now: () -> Date
    /// Whether anyone is signed in; nothing is sent otherwise.
    var isSignedIn: () -> Bool = { false }
    private var lastSent: [AppFeature: Date] = [:]

    /// The same feature twice within this long counts once.
    static let repeatWindow: TimeInterval = 60

    init(api: ReleaseAPI, preferences: Preferences, now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.preferences = preferences
        self.now = now
    }

    /// The app came to the front: counts a session, and sends any crash
    /// report waiting from last time.
    func appOpened() async {
        guard isSignedIn() else {
            return
        }
        try? await api.send(.appOpened)
        await sendPendingCrashReports()
    }

    /// A feature was used. Fire and forget.
    func used(_ feature: AppFeature) {
        guard isSignedIn() else {
            return
        }
        let time = now()
        if let last = lastSent[feature], time.timeIntervalSince(last) < Self.repeatWindow {
            return
        }
        lastSent[feature] = time
        let api = api
        Task { try? await api.send(.used(feature)) }
    }

    /// Keeps crash reports until they reach the server.
    func received(_ reports: [CrashRequest]) async {
        guard !reports.isEmpty else {
            return
        }
        preferences.pendingCrashReports += reports
        await sendPendingCrashReports()
    }

    private func sendPendingCrashReports() async {
        guard isSignedIn() else {
            return
        }
        var left: [CrashRequest] = []
        for report in preferences.pendingCrashReports {
            do {
                try await api.send(report)
            } catch let error as APIError where error.status.map({ (400..<500).contains($0) }) == true {
                // Refused (too large, too many today): don't try this one again.
                continue
            } catch {
                left.append(report)
            }
        }
        preferences.pendingCrashReports = left
    }
}

/// Apple's MetricKit hands over crash and hang reports at the next launch.
/// $0 and built in; nothing leaves the phone except to Sublette's server.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    private let onReports: @Sendable ([CrashRequest]) -> Void

    init(onReports: @escaping @Sendable ([CrashRequest]) -> Void) {
        self.onReports = onReports
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        onReports(payloads.flatMap(Self.reports(from:)))
    }

    static func reports(from payload: MXDiagnosticPayload) -> [CrashRequest] {
        let crashes = (payload.crashDiagnostics ?? []).map { ("crash", $0 as MXDiagnostic) }
        let hangs = (payload.hangDiagnostics ?? []).map { ("hang", $0 as MXDiagnostic) }
        return (crashes + hangs).map { kind, diagnostic in
            report(
                kind: kind,
                appVersion: diagnostic.metaData.applicationBuildVersion,
                osVersion: diagnostic.metaData.osVersion,
                json: diagnostic.jsonRepresentation()
            )
        }
    }

    /// The server takes up to 64 KB of report.
    static func report(kind: String, appVersion: String, osVersion: String, json: Data) -> CrashRequest {
        let text = String(decoding: json.prefix(65_000), as: UTF8.self)
        return CrashRequest(
            kind: kind,
            appVersion: String(appVersion.prefix(20)),
            osVersion: String(osVersion.prefix(40)),
            payload: text.isEmpty ? "{}" : text
        )
    }
}
