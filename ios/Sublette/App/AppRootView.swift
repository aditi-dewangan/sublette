import SwiftUI

/// Decides which screen the app shows: sign-in, profile setup, or the tabs.
@MainActor
struct AppRootView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                LaunchView()
            case .unreachable:
                UnreachableView()
            case .suspended(let message):
                SuspendedView(message: message)
            case .signedOut:
                OnboardingFlowView(model: container.onboarding)
            case .signedIn(let user):
                if user.needsToAcceptTerms {
                    TermsView(user: user)
                } else if !user.profileComplete {
                    ProfileSetupView(container: container, user: user)
                } else if !appState.hasChosenStartingMode(userID: user.id) {
                    StartingModeView(user: user)
                } else {
                    RootView()
                }
            }
        }
        .background(Brand.cream)
    }
}

/// Shown for a moment at launch while the app finds out who is signed in.
@MainActor
struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            PinMark(width: 96)
            Text("Sublette")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.accentText)
            ProgressView()
                .tint(Brand.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.cream)
    }
}

/// Signed in, but the server can't be reached and there is no saved profile to show.
@MainActor
struct UnreachableView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Brand.accentText)
                .accessibilityHidden(true)
            Text("Can't reach Sublette")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)
            Text("You're still signed in. Check your connection and try again.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink)
            Button("Try again") {
                Task { await session.retry() }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Sign out") {
                Task { await session.signOut() }
            }
            .buttonStyle(LinkButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.cream)
    }
}

#Preview("Signed in") {
    AppRootView()
        .previewEnvironment()
}

#Preview("New account") {
    AppRootView()
        .previewEnvironment(signedInAs: PreviewData.newUser)
}

#Preview("Launching") {
    LaunchView()
}

#Preview("Can't reach the server") {
    UnreachableView()
        .previewEnvironment()
}
