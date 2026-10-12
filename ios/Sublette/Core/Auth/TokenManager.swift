import Foundation

/// Owns the signed-in student's tokens and keeps the access token fresh.
///
/// Two rules matter here:
/// * If the server says the session is over (401 or 403 on refresh), the tokens
///   are thrown away and the app is told to sign out.
/// * If the server simply can't be reached, the tokens are kept. Being offline
///   must never sign anyone out.
actor TokenManager: AccessTokenProviding {
    private let store: TokenStore
    private let refresher: TokenRefreshing
    private let now: @Sendable () -> Date
    /// Refresh this long before the access token actually expires.
    private let refreshMargin: TimeInterval = 60

    private var tokens: AuthTokens?
    private var refreshInFlight: Task<AuthTokens?, Never>?
    private var onSessionEnded: (@Sendable () async -> Void)?

    init(
        store: TokenStore,
        refresher: TokenRefreshing,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.refresher = refresher
        self.now = now
        self.tokens = store.load()
    }

    var hasTokens: Bool {
        tokens != nil
    }

    /// Called when the server ends the session, so the app can show sign-in.
    func setSessionEndedHandler(_ handler: @escaping @Sendable () async -> Void) {
        onSessionEnded = handler
    }

    /// Called once the first screen is up. Only then are the Keychain and
    /// UserDefaults certain to be readable (a phone that restarted and has not
    /// been unlocked yet can launch the app with both locked).
    func prepare(preferences: Preferences) {
        FirstLaunch.clearStaleTokensIfNeeded(preferences: preferences, store: store)
        tokens = store.load()
    }

    func setTokens(_ newTokens: AuthTokens) {
        tokens = newTokens
        store.save(newTokens)
    }

    func clear() {
        tokens = nil
        store.clear()
    }

    // MARK: - AccessTokenProviding

    func accessToken() async -> String? {
        guard let current = tokens else {
            return nil
        }
        if current.accessTokenExpiresAt.timeIntervalSince(now()) > refreshMargin {
            return current.accessToken
        }
        if let fresh = await refresh() {
            return fresh.accessToken
        }
        // The refresh failed. If the session ended, `tokens` is now nil. If the
        // server was unreachable, send the old token; the request will fail on
        // its own and the student stays signed in.
        return tokens?.accessToken
    }

    func refreshedAccessToken(afterRejecting rejected: String) async -> String? {
        guard let current = tokens else {
            return nil
        }
        if current.accessToken != rejected {
            // Another request already refreshed while this one was in the air.
            return current.accessToken
        }
        return await refresh()?.accessToken
    }

    // MARK: - Private

    /// Runs one refresh at a time. Callers that arrive while it is running wait for it.
    private func refresh() async -> AuthTokens? {
        if let refreshInFlight {
            return await refreshInFlight.value
        }
        guard let current = tokens else {
            return nil
        }
        let task = Task { await self.performRefresh(using: current.refreshToken) }
        refreshInFlight = task
        let result = await task.value
        refreshInFlight = nil
        return result
    }

    private func performRefresh(using refreshToken: String) async -> AuthTokens? {
        do {
            let response = try await refresher.refresh(using: refreshToken)
            // Signed out (or signed in again) while the request was in the air:
            // these tokens belong to a session that no longer exists.
            guard tokens?.refreshToken == refreshToken else {
                return nil
            }
            let fresh = AuthTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: response.expiresIn,
                now: now()
            )
            setTokens(fresh)
            return fresh
        } catch let error as APIError {
            if let status = error.status, status == 401 || status == 403,
               tokens?.refreshToken == refreshToken {
                // The refresh token is expired, or the account is gone or suspended.
                clear()
                await onSessionEnded?()
            }
            return nil
        } catch {
            return nil
        }
    }
}
