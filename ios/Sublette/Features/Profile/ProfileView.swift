import SwiftUI

/// The Profile tab: the student's own profile, and the account actions.
@MainActor
struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session

    @State private var isEditing = false
    @State private var showsSettings = false

    var body: some View {
        ScrollView {
            if let user = session.user {
                VStack(spacing: 20) {
                    header(user)
                    details(user)
                    actions
                    // Which server the app talks to, and whether it answers.
                    ServerStatusCard()
                        .padding(.top, 12)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Brand.cream)
        .sheet(isPresented: $isEditing) {
            if let user = session.user {
                ProfileEditView(container: container, user: user)
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
    }

    private func header(_ user: User) -> some View {
        VStack(spacing: 12) {
            AvatarView(urlString: user.photoUrl, size: 112)
            Text(user.firstName ?? "Your profile")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)
            VerifiedBadge(schoolName: user.school.name)
            if let done = user.completedSublets, done > 0 {
                Label(done == 1 ? "1 sublet completed" : "\(done) sublets completed", systemImage: "star.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.ink)
            }
            if let year = user.year, let program = user.program {
                Text("\(year.title) · \(program)")
                    .font(.subheadline)
                    .foregroundStyle(Brand.ink)
            }
        }
    }

    private func details(_ user: User) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let bio = user.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row("Email", user.email)
            if let smokes = user.smokes {
                row("Smokes", smokes ? "Yes" : "No")
            }
            if let hasPets = user.hasPets {
                row("Has pets", hasPets ? "Yes" : "No")
            }
            if let gender = user.gender {
                row("Gender", gender.title)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Brand.ink.opacity(0.7))
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button("Edit profile") { isEditing = true }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("edit-profile-button")
            Button("Sign out") {
                Task { await session.signOut() }
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("sign-out-button")

            Button("Settings") { showsSettings = true }
                .buttonStyle(LinkButtonStyle())
                .padding(.top, 8)
                .accessibilityIdentifier("settings-button")
            Text("Blocked people, terms, contact us, and deleting your account.")
                .font(.footnote)
                .foregroundStyle(Brand.ink.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }
}

#Preview {
    ProfileView()
        .previewEnvironment()
}
