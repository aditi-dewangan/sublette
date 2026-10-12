import SwiftUI

/// Sign-up and sign-in. Shown whenever nobody is signed in.
@MainActor
struct OnboardingFlowView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        Group {
            switch model.step {
            case .email:
                EmailEntryView(model: model)
            case .code:
                CodeEntryView(model: model)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.step)
    }
}

/// The shared frame of the onboarding screens.
@MainActor
struct OnboardingPage<Content: View>: View {
    private let title: String
    private let subtitle: String
    private let content: () -> Content

    init(title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Sublette")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(Brand.magenta)
                    .padding(.top, 32)
                Text(title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.cream)
    }
}

@MainActor
struct EmailEntryView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var isFocused: Bool

    var body: some View {
        OnboardingPage(
            title: "Your room, their quarter.",
            subtitle: "Sublette is for verified students. Enter your school email and we'll send you a code."
        ) {
            FormField("School email", error: model.errorMessage) {
                TextField("you@school.edu", text: $model.email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($isFocused)
                    .onSubmit { send() }
                    .brandField()
                    .accessibilityIdentifier("email-field")
            }
            Button(sendTitle) { send() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isWorking)
                .accessibilityIdentifier("send-code-button")
            Text("Verified students only. Any .edu email works.")
                .font(.footnote)
                .foregroundStyle(Brand.ink.opacity(0.7))
        }
        .onAppear { isFocused = true }
    }

    private var sendTitle: String {
        model.isWorking ? "Sending…" : "Send code"
    }

    private func send() {
        Task { await model.submitEmail() }
    }
}

@MainActor
struct CodeEntryView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var isFocused: Bool

    var body: some View {
        OnboardingPage(
            title: "Check your email.",
            subtitle: "We sent a 6-digit code to \(model.sentTo). It works for 10 minutes."
        ) {
            FormField("Code", error: model.errorMessage) {
                TextField("123456", text: $model.code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .focused($isFocused)
                    .brandField()
                    .accessibilityIdentifier("code-field")
            }
            Button(verifyTitle) { verify() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isWorking)
                .accessibilityIdentifier("verify-button")
            HStack {
                Button("Change email") { model.changeEmail() }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(model.isWorking)
                Spacer()
                // Redraws once a second so the countdown ticks.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = model.secondsUntilResend(at: context.date)
                    let title: String = wait > 0 ? "Resend in \(wait)s" : "Resend code"
                    Button(title) {
                        Task { await model.resend() }
                    }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(wait > 0 || model.isWorking)
                    .opacity(wait > 0 ? 0.5 : 1)
                }
            }
        }
        .onAppear { isFocused = true }
        .onChange(of: model.code) { _, newValue in
            // Keep digits only, and verify as soon as all six are in.
            let digits = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(6))
            if digits != newValue {
                model.code = digits
            } else if digits.count == 6 {
                verify()
            }
        }
    }

    private var verifyTitle: String {
        model.isWorking ? "Checking…" : "Verify"
    }

    private func verify() {
        Task { await model.submitCode() }
    }
}

/// The last onboarding step: which side to start on.
@MainActor
struct StartingModeView: View {
    let user: User
    @Environment(AppState.self) private var appState

    var body: some View {
        OnboardingPage(
            title: "Where do you want to start?",
            subtitle: "One account does both. You can switch any time from the top of the screen."
        ) {
            modeCard(
                .renter,
                title: "I need a place",
                detail: "Say what you need, drop a pin, and swipe on rooms.",
                systemImage: "magnifyingglass"
            )
            modeCard(
                .lister,
                title: "I have a place to sublet",
                detail: "Post your room and choose who takes it over.",
                systemImage: "key.fill"
            )
        }
    }

    private func modeCard(
        _ mode: AppMode,
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Button {
            appState.chooseStartingMode(mode, userID: user.id)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(mode.textOnAccent)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mode.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("start-as-\(mode.rawValue)")
    }
}

#Preview("Email") {
    EmailEntryView(model: AppContainer.preview(signedInAs: nil).onboarding)
}

#Preview("Code") {
    let model = AppContainer.preview(signedInAs: nil).onboarding
    model.showCodeStepForPreview(sentTo: "aditi@uw.edu")
    return CodeEntryView(model: model)
}

#Preview("Starting mode") {
    StartingModeView(user: PreviewData.aditi)
        .previewEnvironment()
}
