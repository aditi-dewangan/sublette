import Foundation
import Observation

/// Who is signed in. The root of the app shows a different screen for each state.
@MainActor
@Observable
final class SessionModel {
    enum State: Equatable {
        /// Just launched; still finding out.
        case restoring
        case signedOut
        case signedIn(User)
        /// There are tokens, but no profile has ever loaded and the server can't be reached.
        case unreachable
    }

    private(set) var state: State = .restoring

    private let api: AccountAPI
    private let tokens: TokenManager
    private let preferences: Preferences
    private let now: () -> Date

    init(
        api: AccountAPI,
        tokens: TokenManager,
        preferences: Preferences,
        now: @escaping () -> Date = { Date() }
    ) {
        self.api = api
        self.tokens = tokens
        self.preferences = preferences
        self.now = now
    }

    var user: User? {
        if case .signedIn(let user) = state {
            return user
        }
        return nil
    }

    /// Called once at launch. Reopening the app keeps the student signed in.
    func restore() async {
        guard await tokens.hasTokens else {
            preferences.cachedUser = nil
            state = .signedOut
            return
        }
        if let cached = preferences.cachedUser, cached.profileComplete {
            // Show the app straight away, even offline, then refresh quietly.
            // An unfinished profile is not shown from the saved copy: it can't
            // be finished offline, and its answers may be out of date.
            state = .signedIn(cached)
        }
        await loadProfile()
    }

    /// Try again from the "can't reach Sublette" screen.
    func retry() async {
        state = .restoring
        await restore()
    }

    /// Called after the code was accepted.
    func completeSignIn(_ response: SessionResponse) async {
        await tokens.setTokens(
            AuthTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: response.expiresIn,
                now: now()
            )
        )
        setSignedIn(response.user)
    }

    /// Called after the profile was saved.
    func update(_ user: User) {
        // A save that finishes after sign-out must not sign the student back in.
        guard state != .signedOut else {
            return
        }
        setSignedIn(user)
    }

    /// Forgets this phone's tokens. The account itself is untouched.
    func signOut() async {
        await tokens.clear()
        preferences.cachedUser = nil
        state = .signedOut
    }

    /// Deletes the account on the server, then signs out. If the server can't
    /// be reached the account is not deleted, the student stays signed in, and
    /// the error is thrown so the screen can say so.
    func deleteAccount() async throws {
        try await api.deleteAccount()
        await signOut()
    }

    /// The server ended the session: the refresh token expired, or the account
    /// was deleted or suspended.
    func sessionEnded() async {
        await signOut()
    }

    // MARK: - Private

    private func setSignedIn(_ user: User) {
        preferences.cachedUser = user
        state = .signedIn(user)
    }

    private func loadProfile() async {
        do {
            let fresh = try await api.me()
            // Signed out while the request was in the air: stay signed out.
            guard state != .signedOut else {
                return
            }
            setSignedIn(fresh)
        } catch let error as APIError {
            guard state != .signedOut else {
                return
            }
            if await serverEndedTheSession(error) {
                await signOut()
            } else if user == nil {
                // Offline or the server is down, and nothing saved to show.
                state = .unreachable
            }
            // Otherwise: keep showing the saved profile. Offline is not signed out.
        } catch {
            guard state != .signedOut else {
                return
            }
            if user == nil {
                state = .unreachable
            }
        }
    }

    /// True when the server has said this session is over, as opposed to a
    /// request that failed on a bad connection.
    private func serverEndedTheSession(_ error: APIError) async -> Bool {
        if error.status == 403 {
            // The account is suspended.
            return true
        }
        if error.status == 401 {
            // A 401 reaches here only after the token manager tried to refresh.
            // If the server refused the refresh, the tokens are already gone.
            // If the refresh merely could not reach the server, they are still
            // here, and the student stays signed in.
            return !(await tokens.hasTokens)
        }
        return false
    }
}
