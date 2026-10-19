import SwiftUI

/// One chat: the checklist pinned on top, the messages, and the composer.
/// Before your first message the safety card stands in for the composer.
@MainActor
struct ChatView: View {
    let model: ChatModel

    @Environment(AppContainer.self) private var container
    @State private var confirmingFilled = false
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ChecklistPanel(model: model, confirmFilled: { confirmingFilled = true })
            Divider()
            messageList
            if let problem = model.problem {
                ErrorText(problem)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.showsSafetyCard {
                SafetyCard { model.acknowledgeSafety() }
                    .padding(16)
            } else {
                suggestions
                composer
            }
        }
        .background(Brand.cream)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    AvatarView(urlString: model.other.photoUrl, size: 30)
                    Text(model.other.firstName ?? "Your match")
                        .font(.headline)
                        .foregroundStyle(Brand.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .confirmationDialog(filledQuestion, isPresented: $confirmingFilled, titleVisibility: .visible) {
            Button(model.role == .lister ? "Mark filled" : "Yes, I'm taking it") {
                Task { await model.confirmFilled() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(filledExplanation)
        }
        .task { await model.load() }
        .onDisappear { container.matchesModel.closeChat(model) }
    }

    private var filledQuestion: String {
        model.role == .lister ? "Mark this place filled?" : "Confirm you're taking this place?"
    }

    private var filledExplanation: String {
        let name = model.other.firstName ?? "your match"
        return model.role == .lister
            ? "It leaves every deck and the map, and can't be undone. When \(name) confirms too, the sublet counts on both your profiles."
            : "When \(name) confirms too, the sublet counts on both your profiles."
    }

    private var messageList: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ListingSummary(match: model.match)
                        .padding(.bottom, 8)
                    if model.hasOlder {
                        Button("Show earlier messages") { Task { await model.loadOlder() } }
                            .buttonStyle(LinkButtonStyle())
                            .frame(maxWidth: .infinity)
                    }
                    if model.state == .loading {
                        ProgressView().tint(Brand.ink).frame(maxWidth: .infinity)
                    } else if case .failed(let message) = model.state, model.messages.isEmpty {
                        ErrorText(message)
                    }
                    ForEach(model.messages) { message in
                        Bubble(text: message.body, mine: message.mine)
                            .id(message.id)
                    }
                    ForEach(model.pending) { message in
                        PendingBubble(message: message, model: model)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count + model.pending.count) {
                withAnimation { reader.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { reader.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if !model.suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.suggestions, id: \.self) { question in
                        Button(question) { Task { await model.send(question) } }
                            .font(.subheadline)
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                            .overlay(Capsule().stroke(Brand.ink.opacity(0.2)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .accessibilityLabel("Suggested first questions")
        }
    }

    private var composer: some View {
        @Bindable var model = model
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composing)
                .brandField()
                .accessibilityIdentifier("message-field")
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Brand.magenta)
            }
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("send-button")
        }
        .padding(16)
    }
}

/// The steps to a sublet, ticked by either side, and "Filled".
@MainActor
private struct ChecklistPanel: View {
    let model: ChatModel
    let confirmFilled: () -> Void
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Checklist.Step.allCases) { step in
                    Button {
                        Task { await model.toggle(step) }
                    } label: {
                        Label(step.title, systemImage: model.match.checklist[step] ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Brand.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(model.match.checklist[step] ? "Done" : "Not done")
                }
                filled
            }
            .padding(.top, 8)
        } label: {
            Text("Checklist · \(model.match.checklist.doneCount) of \(Checklist.Step.allCases.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
        }
        .tint(Brand.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(model.role == .renter ? Brand.yellow.opacity(0.25) : Brand.orange.opacity(0.2))
    }

    @ViewBuilder
    private var filled: some View {
        let name = model.other.firstName ?? "Your match"
        if model.match.filled.completed {
            Label("Sublet complete. It counts on both your profiles.", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
        } else if model.awaitsMyFilled {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.role == .renter
                    ? "\(name) marked the place filled. Are you taking it?"
                    : "\(name) says they're taking the place.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.ink)
                Button(model.role == .renter ? "Confirm" : "Mark filled", action: confirmFilled)
                    .buttonStyle(SecondaryButtonStyle())
            }
        } else if model.match.filled.confirmed(by: model.role) {
            Text("You marked it filled. Waiting for \(name) to confirm.")
                .font(.footnote)
                .foregroundStyle(Brand.ink.opacity(0.75))
        } else {
            Button(model.role == .lister ? "Mark filled" : "I'm taking this place", action: confirmFilled)
                .buttonStyle(LinkButtonStyle())
        }
    }
}

/// What the match is about. A matched renter sees the exact address.
private struct ListingSummary: View {
    let match: Match

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(match.listing.title)
                .font(.headline)
            if let dates = match.listing.dateSummary {
                Text(dates).font(.subheadline)
            }
            if let address = match.listing.address {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            if match.listing.status == .filled {
                Text("Filled").font(.footnote.weight(.semibold))
            }
            if match.other.completedSublets > 0 {
                Text(match.other.completedSublets == 1
                    ? "\(match.other.firstName ?? "They") finished 1 sublet on Sublette"
                    : "\(match.other.firstName ?? "They") finished \(match.other.completedSublets) sublets on Sublette")
                    .font(.footnote)
            }
        }
        .foregroundStyle(Brand.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct Bubble: View {
    let text: String
    let mine: Bool

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(mine ? Brand.textOnMagenta : Brand.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(mine ? Brand.magenta : Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 290, alignment: mine ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .textSelection(.enabled)
    }
}

@MainActor
private struct PendingBubble: View {
    let message: PendingMessage
    let model: ChatModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Bubble(text: message.body, mine: true)
                .opacity(message.failed ? 0.5 : 0.7)
            if message.failed {
                HStack(spacing: 12) {
                    Button("Not sent. Try again") { Task { await model.retry(message) } }
                    Button("Delete", role: .destructive) { model.discard(message) }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.magenta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Read once per chat, before your first message.
struct SafetyCard: View {
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Before you chat", systemImage: "shield.lefthalf.filled")
                .font(.headline)
            Text("• Tour the place, in person or on video, before you pay anything.")
            Text("• Never wire money or pay with gift cards.")
            Text("• Get the landlord's consent to the sublet in writing.")
            Button("Got it", action: onAcknowledge)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("safety-got-it")
        }
        .font(.subheadline)
        .foregroundStyle(Brand.ink)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview("Chat") {
    let container = AppContainer.preview()
    let model = ChatModel(match: PreviewData.match, api: PreviewChatAPI(), preferences: .ephemeral(), userID: "user-3")
    return NavigationStack {
        ChatView(model: model)
    }
    .environment(container)
}

#Preview("Safety card") {
    SafetyCard {}
        .padding()
        .background(Brand.cream)
}
