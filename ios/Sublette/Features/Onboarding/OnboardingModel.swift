import Foundation
import Observation

/// Sign-up and sign-in: enter a .edu email, then the six-digit code sent to it.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Equatable {
        case email
        case code
    }

    var email = ""
    var code = ""
    private(set) var step: Step = .email
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// The address the code was sent to, trimmed and lowercased.
    private(set) var sentTo = ""
    /// When another code may be requested.
    private(set) var resendAvailableAt: Date?

    private let api: AccountAPI
    private let session: SessionModel
    private let now: () -> Date

    static let notEduMessage = "Sublette is for students. Use your school email ending in .edu."
    static let invalidEmailMessage = "Enter your school email address."
    static let invalidCodeMessage = "Enter the 6-digit code from the email."

    init(api: AccountAPI, session: SessionModel, now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.session = session
        self.now = now
    }

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A quick check before asking the server, which makes the real decision.
    /// Returns the message to show, or nil if the address looks usable.
    func localEmailProblem() -> String? {
        let parts = normalizedEmail.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !normalizedEmail.contains(" ")
        else {
            return Self.invalidEmailMessage
        }
        guard parts[1].hasSuffix(".edu") else {
            return Self.notEduMessage
        }
        return nil
    }

    /// Seconds until another code may be requested. Zero means now.
    func secondsUntilResend(at date: Date) -> Int {
        guard let resendAvailableAt else {
            return 0
        }
        return max(0, Int(resendAvailableAt.timeIntervalSince(date).rounded(.up)))
    }

    func submitEmail() async {
        guard !isWorking else {
            return
        }
        if let problem = localEmailProblem() {
            errorMessage = problem
            return
        }
        if await requestCode(for: normalizedEmail) {
            code = ""
            step = .code
        }
    }

    func resend() async {
        guard !isWorking, step == .code, secondsUntilResend(at: now()) == 0 else {
            return
        }
        if await requestCode(for: sentTo) {
            code = ""
        }
    }

    func submitCode() async {
        guard !isWorking else {
            return
        }
        let digits = code.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 6 else {
            errorMessage = Self.invalidCodeMessage
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let response = try await api.verify(email: sentTo, code: digits)
            await session.completeSignIn(response)
            reset()
        } catch let error as APIError {
            code = ""
            if case .cancelled = error {
                return
            }
            errorMessage = error.userMessage
        } catch {
            code = ""
            errorMessage = APIError.unreachable.userMessage
        }
    }

    /// Back to the email step, to fix a typo.
    func changeEmail() {
        step = .email
        code = ""
        errorMessage = nil
    }

    func reset() {
        email = ""
        code = ""
        sentTo = ""
        step = .email
        errorMessage = nil
        resendAvailableAt = nil
    }

    // MARK: - Private

    private func requestCode(for address: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let response = try await api.requestCode(email: address)
            sentTo = address
            resendAvailableAt = now().addingTimeInterval(TimeInterval(response.resendIn))
            return true
        } catch let error as APIError {
            if case .cancelled = error {
                return false
            }
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = APIError.unreachable.userMessage
            return false
        }
    }
}

extension OnboardingModel {
    /// For previews: jump straight to the code step.
    func showCodeStepForPreview(sentTo address: String) {
        sentTo = address
        step = .code
    }
}
