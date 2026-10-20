import SwiftUI

/// The "…" menu on every profile, listing and chat: report, and block.
@MainActor
struct SafetyMenu: View {
    /// What can be reported from here, such as the person and their listing.
    let reports: [ReportSubject]
    var block: BlockSubject?
    /// Runs after a block went through, as when a chat should close.
    var onBlocked: () -> Void = {}

    @Environment(AppContainer.self) private var container
    @State private var reporting: ReportSubject?
    @State private var confirmingBlock = false

    var body: some View {
        Menu {
            ForEach(reports) { subject in
                Button(subject.title, systemImage: "flag") { reporting = subject }
            }
            if let block {
                Button(block.title, systemImage: "hand.raised", role: .destructive) {
                    confirmingBlock = true
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(Brand.ink)
                .padding(6)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Report or block")
        .accessibilityIdentifier("safety-menu")
        .sheet(item: $reporting) { subject in
            ReportSheet(subject: subject, block: block, onBlocked: onBlocked)
        }
        .modifier(BlockConfirmation(subject: block, isPresented: $confirmingBlock, onBlocked: onBlocked))
    }
}

/// "Block Sam?" with what a block does.
@MainActor
struct BlockConfirmation: ViewModifier {
    let subject: BlockSubject?
    @Binding var isPresented: Bool
    var onBlocked: () -> Void = {}

    @Environment(AppContainer.self) private var container

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "\(subject?.title ?? "Block")?",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            if let subject {
                Button("Block", role: .destructive) {
                    Task {
                        if await container.safety.block(subject) {
                            container.analytics.used(.block)
                            onBlocked()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(BlockConfirmation.explanation(for: subject))
        }
    }

    static func explanation(for subject: BlockSubject?) -> String {
        let name = subject?.name ?? "They"
        return "\(name) won't see you, and you won't see them: no listings, matches or messages either way. They aren't told. You can unblock in Settings."
    }
}

/// Why it's being reported, anything else to add, and then an offer to block.
@MainActor
struct ReportSheet: View {
    let subject: ReportSubject
    var block: BlockSubject?
    var onBlocked: () -> Void = {}

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var sending = false
    @State private var sent = false
    @State private var confirmingBlock = false

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        Label("Thanks. We'll review it soon.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.ink)
                        Text("Reports are private: nobody is told who made one.")
                            .font(.footnote)
                            .foregroundStyle(Brand.ink.opacity(0.75))
                    }
                    if let block {
                        Section {
                            Button(block.title, role: .destructive) { confirmingBlock = true }
                        } footer: {
                            Text(BlockConfirmation.explanation(for: block))
                        }
                    }
                } else {
                    Section("What's wrong?") {
                        ForEach(ReportReason.allCases) { option in
                            Button {
                                reason = option
                            } label: {
                                HStack {
                                    Text(option.title).foregroundStyle(Brand.ink)
                                    Spacer()
                                    if reason == option {
                                        Image(systemName: "checkmark").foregroundStyle(Brand.accentText)
                                    }
                                }
                            }
                            .accessibilityAddTraits(reason == option ? .isSelected : [])
                        }
                    }
                    Section {
                        TextField("Anything else we should know (optional)", text: $details, axis: .vertical)
                            .lineLimit(2...6)
                    } footer: {
                        Text("If you're in danger, call 911 first.")
                    }
                    if let problem = container.safety.problem {
                        Section { ErrorText(problem) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.cream)
            .navigationTitle(subject.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(sending ? "Sending…" : "Send") { send() }
                            .disabled(reason == nil || sending)
                            .accessibilityIdentifier("send-report")
                    }
                }
            }
            .modifier(BlockConfirmation(subject: block, isPresented: $confirmingBlock) {
                dismiss()
                onBlocked()
            })
        }
        .tint(Brand.accentText)
    }

    private func send() {
        guard let reason else {
            return
        }
        sending = true
        Task {
            sent = await container.safety.report(subject, reason: reason, details: details)
            if sent {
                container.analytics.used(.report)
            }
            sending = false
        }
    }
}

/// Settings: blocked people, the terms, contact, and deleting the account.
@MainActor
struct SettingsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteProblem: String?
    @State private var alertProblem: String?

    /// Saved as soon as it changes; shown as the server has it.
    private var alertFrequency: Binding<AlertFrequency> {
        Binding(
            get: { session.user?.alertFrequency ?? .daily },
            set: { chosen in
                alertProblem = nil
                Task {
                    do {
                        session.update(try await container.api.setAlertFrequency(chosen))
                    } catch {
                        alertProblem = SafetyModel.message(for: error)
                    }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Alerts", selection: alertFrequency) {
                        ForEach(AlertFrequency.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .accessibilityIdentifier("alert-frequency")
                    if let alertProblem {
                        ErrorText(alertProblem)
                    }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Price drops and closing-soon reminders for places you liked or saved, new places that fit your search, and a weekly note to listers about new likes.")
                }
                Section("Safety") {
                    NavigationLink("Blocked people") { BlockedPeopleView() }
                        .accessibilityIdentifier("blocked-people")
                }
                if session.user?.referred == false {
                    Section {
                        NavigationLink("Add a friend's referral code") { ReferralEntryView() }
                    } footer: {
                        Text("For new listers, before your first listing goes live.")
                    }
                }
                Section("About") {
                    if let terms = container.pageURL(.termsPage) {
                        Link("Terms of service", destination: terms)
                    }
                    if let privacy = container.pageURL(.privacyPage) {
                        Link("Privacy policy", destination: privacy)
                    }
                    if let contact = AppConfiguration.contactURL() {
                        Link("Contact us", destination: contact)
                    }
                }
                Section {
                    if let deleteProblem {
                        ErrorText(deleteProblem)
                    }
                    Button(deleting ? "Deleting…" : "Delete account", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(deleting)
                    .accessibilityIdentifier("delete-account-button")
                } footer: {
                    Text("Removes your profile, listings, swipes and messages from Sublette.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.cream)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) { deleteAccount() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes your profile, listings, swipes and messages. It can't be undone.")
            }
        }
        .tint(Brand.accentText)
    }

    private func deleteAccount() {
        deleting = true
        deleteProblem = nil
        Task {
            do {
                try await session.deleteAccount()
            } catch {
                // Nothing was deleted. Say so, and leave the student signed in.
                deleteProblem = "Your account was not deleted. \(SafetyModel.message(for: error))"
            }
            deleting = false
        }
    }
}

/// A new lister adds the code a friend gave them.
@MainActor
struct ReferralEntryView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var problem: String?
    @State private var sending = false

    var body: some View {
        Form {
            Section {
                TextField("Code, such as K7P2QXM", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } footer: {
                Text("Your friend finds their code on their Profile tab.")
            }
            if let problem {
                Section { ErrorText(problem) }
            }
            Section {
                Button(sending ? "Adding…" : "Add code") { add() }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 4 || sending)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.cream)
        .navigationTitle("Referral code")
    }

    private func add() {
        sending = true
        problem = nil
        Task {
            do {
                session.update(try await container.releaseAPI.useReferral(code: code))
                container.analytics.used(.referral)
                dismiss()
            } catch {
                problem = SafetyModel.message(for: error)
            }
            sending = false
        }
    }
}

@MainActor
struct BlockedPeopleView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let model = container.safety
        List {
            if let problem = model.problem {
                ErrorText(problem)
            }
            if model.blocked.isEmpty && !model.isLoadingBlocked {
                Text("You haven't blocked anyone.")
                    .foregroundStyle(Brand.ink.opacity(0.75))
            }
            ForEach(model.blocked) { person in
                HStack(spacing: 12) {
                    AvatarView(urlString: person.photoUrl, size: 36)
                    Text(person.firstName ?? "Someone")
                        .foregroundStyle(Brand.ink)
                    Spacer()
                    Button("Unblock") { Task { await model.unblock(person) } }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.cream)
        .navigationTitle("Blocked people")
        .task { await model.loadBlocked() }
        .refreshable { await model.loadBlocked() }
    }
}

/// Shown once per new version of the terms, before anything else.
@MainActor
struct TermsView: View {
    let user: User

    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session
    @State private var accepting = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Before you start")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Sublette is for students helping students. By continuing you agree to keep it honest and kind:")
                VStack(alignment: .leading, spacing: 10) {
                    Label("Post only real places you're allowed to sublet.", systemImage: "house")
                    Label("No scams, harassment or discrimination.", systemImage: "hand.raised")
                    Label("Never pay before touring, and never wire money.", systemImage: "creditcard")
                }
                HStack(spacing: 16) {
                    if let terms = container.pageURL(.termsPage) {
                        Link("Terms of service", destination: terms)
                    }
                    if let privacy = container.pageURL(.privacyPage) {
                        Link("Privacy policy", destination: privacy)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(Brand.accentText)
                if let problem {
                    ErrorText(problem)
                }
                Button(accepting ? "One moment…" : "I agree") { accept() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(accepting)
                    .accessibilityIdentifier("accept-terms")
                Button("Sign out") { Task { await session.signOut() } }
                    .buttonStyle(LinkButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(Brand.ink)
            .padding(24)
        }
        .background(Brand.cream)
    }

    private func accept() {
        accepting = true
        problem = nil
        Task {
            do {
                let updated = try await container.safetyAPI.acceptTerms(version: user.termsVersion ?? "")
                session.update(updated)
            } catch {
                problem = SafetyModel.message(for: error)
                // The terms changed while this screen was open: show the new ones.
                if (error as? APIError)?.serverCode == "terms_outdated" {
                    await session.retry()
                }
            }
            accepting = false
        }
    }
}

/// A suspended account sees only this: why, and how to appeal.
@MainActor
struct SuspendedView: View {
    let message: String

    @Environment(SessionModel.self) private var session

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Brand.accentText)
                .accessibilityHidden(true)
            Text("Your account is suspended")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("To appeal, write to us from your school email and tell us what happened. We read every appeal.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.ink.opacity(0.8))
            if let contact = AppConfiguration.contactURL(subject: "Appeal") {
                Link("Email us to appeal", destination: contact)
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("Sign out") { Task { await session.signOut() } }
                .buttonStyle(LinkButtonStyle())
        }
        .foregroundStyle(Brand.ink)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.cream)
    }
}

#Preview("Report") {
    ReportSheet(subject: .listing(id: "l1"), block: .listerOf(listingID: "l1", name: "Lee"))
        .environment(AppContainer.preview())
}

#Preview("Settings") {
    SettingsView()
        .previewEnvironment()
}

#Preview("Blocked people") {
    NavigationStack {
        BlockedPeopleView()
    }
    .environment(AppContainer.preview())
}

#Preview("Terms") {
    TermsView(user: PreviewData.aditi)
        .previewEnvironment()
}

#Preview("Suspended") {
    SuspendedView(
        message: "This account has been suspended for asking renters to pay before a tour. To appeal, email subletteofficial@gmail.com from your school address."
    )
    .previewEnvironment()
}
