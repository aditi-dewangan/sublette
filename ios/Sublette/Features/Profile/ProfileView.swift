import SwiftUI

/// The Profile tab: the student's own profile, and the account actions.
@MainActor
struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session

    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var accountMessage: String?

    var body: some View {
        ScrollView {
            if let user = session.user {
                VStack(spacing: 20) {
                    header(user)
                    details(user)
                    actions
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
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your profile, listings, swipes and messages. It can't be undone.")
        }
    }

    private func header(_ user: User) -> some View {
        VStack(spacing: 12) {
            AvatarView(urlString: user.photoUrl, size: 112)
            Text(user.firstName ?? "Your profile")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)
            VerifiedBadge(schoolName: user.school.name)
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

            if let accountMessage {
                ErrorText(accountMessage)
            }
            Button(isDeleting ? "Deleting…" : "Delete account") {
                isConfirmingDelete = true
            }
            .buttonStyle(LinkButtonStyle())
            .disabled(isDeleting)
            .padding(.top, 8)
            .accessibilityIdentifier("delete-account-button")
        }
    }

    private func deleteAccount() {
        isDeleting = true
        accountMessage = nil
        Task {
            do {
                try await session.deleteAccount()
            } catch let error as APIError {
                // Nothing was deleted. Say so, and leave the student signed in.
                accountMessage = "Your account was not deleted. \(error.userMessage)"
            } catch {
                accountMessage = "Your account was not deleted. Try again."
            }
            isDeleting = false
        }
    }
}

#Preview {
    ProfileView()
        .previewEnvironment()
}
