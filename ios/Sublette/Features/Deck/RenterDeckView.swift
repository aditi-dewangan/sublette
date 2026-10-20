import SwiftUI

/// The renter's deck: the card stack, its buttons, and what to do when it's empty.
@MainActor
struct RenterDeckView: View {
    @State private var showsAssistant = false
    @Environment(AppContainer.self) private var container
    let onEditSearch: (PreferencesEditorModel.Step) -> Void

    @State private var details: DeckItem?

    private var model: RenterDeckModel { container.renterDeck }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            if model.outbox.isOffline || model.showingSaved {
                OfflineBanner { Task { await model.reload() } }
            }
            if let message = model.message {
                ErrorText(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            content
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(Brand.cream)
        .task {
            if model.state == .idle {
                await model.load()
            }
            // The server decides whether the assistant shows.
            await container.assistant.refreshStatus()
        }
        .sheet(isPresented: $showsAssistant) {
            AssistantView()
        }
        .sheet(item: $details) { item in
            DeckDetailSheet(item: item)
        }
    }

    private var toolbar: some View {
        HStack {
            Text("For you")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)
            Spacer()
            if container.assistant.isEnabled {
                Button {
                    showsAssistant = true
                } label: {
                    Label("Ask", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                }
                .accessibilityLabel("Ask Sublette for places")
                .accessibilityIdentifier("open-assistant")
            }
            Menu {
                Button("Dates and budget") { onEditSearch(.dates) }
                Button("What matters") { onEditSearch(.preferences) }
                Button("Where") { onEditSearch(.area) }
            } label: {
                Label("Your search", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.ink)
            }
            .accessibilityIdentifier("edit-search-menu")
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        if case .notReady(let message) = model.state {
            VStack(spacing: 14) {
                Text(message)
                    .font(.body)
                    .foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.center)
                Button("Edit your search") { onEditSearch(.dates) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 40)
        } else if !model.cards.isEmpty {
            VStack(spacing: 16) {
                SwipeCardStack(
                    items: model.cards,
                    onLike: { Task { await model.like() } },
                    onPass: { Task { await model.pass() } }
                ) { item in
                    DeckCardView(item: item) { details = item }
                }
                .frame(maxHeight: .infinity)
                buttons
            }
        } else if case .failed(let message) = model.state {
            VStack(spacing: 14) {
                ErrorText(message)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 40)
        } else if model.isEmpty {
            ScrollView {
                EmptyDeckView(
                    diagnostics: model.diagnostics,
                    onEditSearch: onEditSearch
                )
            }
        } else {
            ProgressView()
                .tint(Brand.accentText)
                .padding(.top, 60)
        }
    }

    private var buttons: some View {
        HStack(spacing: 18) {
            DeckButton(systemImage: "arrow.uturn.backward", label: "Undo", size: 48) {
                Task {
                    container.analytics.used(.undo)
                    await model.undo()
                }
            }
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.4)
            DeckButton(systemImage: "xmark", label: "Pass") {
                Task { await model.pass() }
            }
            .accessibilityIdentifier("deck-pass")
            DeckButton(systemImage: "bookmark", label: "Save for later", size: 48) {
                Task { await model.save() }
            }
            DeckButton(systemImage: "heart.fill", label: "Like", color: Brand.magenta) {
                Task { await model.like() }
            }
            .accessibilityIdentifier("deck-like")
        }
    }
}

/// Swipes made offline are kept and sent later.
struct OfflineBanner: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "wifi.slash")
                .accessibilityHidden(true)
            Text("You're offline. Your swipes are kept on this phone and sent when you're back.")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: onRetry)
                .font(.footnote.weight(.semibold))
                .tint(Brand.accentText)
        }
        .foregroundStyle(Brand.ink)
        .padding(12)
        .background(Brand.orange.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The empty deck: why it's empty, and one button that helps.
@MainActor
struct EmptyDeckView: View {
    @Environment(AppContainer.self) private var container
    @Environment(AppState.self) private var appState
    @Environment(SessionModel.self) private var session
    let diagnostics: DeckDiagnostics?
    let onEditSearch: (PreferencesEditorModel.Step) -> Void

    @State private var isWorking = false
    @State private var isEditingProfile = false

    private var search: RenterSearchModel { container.renterSearch }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
            if let message = search.changeMessage {
                ErrorText(message)
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isWorking)
        .sheet(isPresented: $isEditingProfile) {
            if let user = session.user {
                ProfileEditView(container: container, user: user)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let blocker = diagnostics?.topMustHave ?? diagnostics?.blockers.first
        if let blocker, blocker.kind == .area {
            newArea(blocker)
        } else if let blocker, blocker.kind == .mustHave {
            // Must-haves are the renter's call: explain, never ask them to drop one.
            heading("Nothing nearby has all your must-haves yet")
            paragraph("You only see places with everything you marked as a must-have. \(blocker.message)")
            notifyButton
            Button("Search a bigger area") {
                container.analytics.used(.biggerArea)
                change { await search.widenArea() }
            }
            .buttonStyle(SecondaryButtonStyle())
        } else if let blocker, blocker.field == "gender_missing" {
            heading("Some places are hidden")
            paragraph(blocker.message)
            Button("Add your gender") { isEditingProfile = true }
                .buttonStyle(PrimaryButtonStyle())
        } else if let blocker {
            heading("Nothing fits right now")
            paragraph(blocker.message)
            Button("Edit your search") { onEditSearch(.dates) }
                .buttonStyle(PrimaryButtonStyle())
        } else {
            heading("You've seen everything near your pin")
            paragraph("New listings show up here as soon as they're posted. Saved ones are in Matches.")
            Button("Search a bigger area") {
                container.analytics.used(.biggerArea)
                change { await search.widenArea() }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    @ViewBuilder
    private func newArea(_ blocker: DeckBlocker) -> some View {
        heading("Sublette is new around here")
        paragraph(blocker.message)
        notifyButton
        Button("Search a bigger area") {
            container.analytics.used(.biggerArea)
            change { await search.widenArea() }
        }
        .buttonStyle(SecondaryButtonStyle())
        Button("Have a place? Post the first listing") {
            appState.setMode(.lister)
        }
        .buttonStyle(LinkButtonStyle())
    }

    @ViewBuilder
    private var notifyButton: some View {
        if search.profile?.notifyNewListings == true {
            Label("We'll let you know when a place that fits is listed nearby.", systemImage: "bell.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
        } else {
            Button("Notify me when a place that fits is listed") {
                container.analytics.used(.notifyMe)
                change(reload: false) { await search.setNotifyNewListings(true) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("notify-me-button")
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(.title2, design: .rounded).weight(.bold))
            .foregroundStyle(Brand.ink)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Brand.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func change(reload: Bool = true, _ action: @escaping () async -> Bool) {
        Task {
            isWorking = true
            let changed = await action()
            isWorking = false
            if changed && reload {
                await container.renterDeck.reload()
            }
        }
    }
}

#Preview("Deck") {
    RenterDeckView(onEditSearch: { _ in })
        .previewEnvironment()
}

#Preview("Nothing nearby") {
    EmptyDeckView(
        diagnostics: DeckDiagnostics(
            inArea: 0, eligible: 0, seen: 0,
            topMustHave: DeckBlocker(
                field: "radius", kind: .area, removed: 0,
                message: "No listings within 3.0 miles of your pin yet. Try a bigger area."
            ),
            blockers: []
        ),
        onEditSearch: { _ in }
    )
    .padding()
    .previewEnvironment()
}
