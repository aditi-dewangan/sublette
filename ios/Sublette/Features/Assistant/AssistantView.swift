import SwiftUI

/// Renter mode's assistant: a text box, then the suggestions as the normal
/// listing cards with the reason for each, and a button to keep what it
/// understood in the search.
@MainActor
struct AssistantView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var details: DeckItem?
    @FocusState private var typing: Bool

    private var model: AssistantModel { container.assistant }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Describe the place you want, in your own words.")
                        .font(.headline)
                    TextField("Furnished room for the summer under $1,200", text: $model.message, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($typing)
                        .submitLabel(.search)
                        .onSubmit { Task { await model.ask() } }
                        .brandField()
                        .accessibilityIdentifier("assistant-message")
                    if model.answer == nil {
                        examples
                    }
                    Button(model.state == .asking ? "Looking…" : "Find places") {
                        typing = false
                        Task { await model.ask() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.message.trimmingCharacters(in: .whitespaces).isEmpty || model.state == .asking)
                    .accessibilityIdentifier("assistant-ask")
                    if case .failed(let message) = model.state {
                        ErrorText(message)
                    }
                    if let answer = model.answer {
                        results(answer)
                    }
                    Label(model.label, systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(Brand.ink.opacity(0.75))
                        .padding(.top, 8)
                }
                .foregroundStyle(Brand.ink)
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Brand.cream)
            .navigationTitle("Ask Sublette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $details) { item in
                DeckDetailSheet(item: item)
            }
        }
        .tint(Brand.accentText)
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For example")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.ink.opacity(0.75))
            ForEach(AssistantModel.examples, id: \.self) { example in
                Button(example) {
                    model.message = example
                }
                .font(.subheadline)
                .foregroundStyle(Brand.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Brand.card, in: Capsule())
                .overlay(Capsule().stroke(Brand.ink.opacity(0.15)))
            }
        }
    }

    @ViewBuilder
    private func results(_ answer: AssistantAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What I understood")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.ink.opacity(0.75))
            Text(answer.summary)
                .font(.subheadline.weight(.semibold))
            if !answer.understood.isEmpty {
                if model.savedPreferences {
                    Label("Saved to your search", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Button("Save these preferences to my search") {
                        Task { await model.saveUnderstood() }
                    }
                    .buttonStyle(LinkButtonStyle())
                    .accessibilityIdentifier("assistant-save-preferences")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        if answer.items.isEmpty {
            Text("Nothing on Sublette fits that yet. Try fewer must-haves, other dates or a bigger area.")
                .font(.subheadline)
        }
        ForEach(answer.items) { suggestion in
            VStack(alignment: .leading, spacing: 10) {
                Label(suggestion.why, systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                DeckCardView(item: suggestion.item) { details = suggestion.item }
                if model.liked.contains(suggestion.id) {
                    Label("Liked. If the lister likes you back, you'll match.", systemImage: "heart.fill")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Button {
                        Task { await model.like(suggestion) }
                    } label: {
                        Label("Like", systemImage: "heart.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }
}

#Preview {
    AssistantView()
        .previewEnvironment()
}
