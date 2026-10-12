import SwiftUI

/// Opens the editor for a new listing or an existing one.
enum EditorRequest: Identifiable {
    case new
    case edit(Listing)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let listing): return listing.id
        }
    }
}

/// Lister mode's home: the student's own listings, and a button to add one.
@MainActor
struct ListerHomeView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session
    @State private var editor: EditorRequest?

    var body: some View {
        let model = container.listerHome
        NavigationStack {
            content(model)
                .background(Brand.cream)
                .navigationTitle("My listings")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editor = .new
                        } label: {
                            Label("Add a listing", systemImage: "plus")
                        }
                        .tint(Brand.magenta)
                        .accessibilityIdentifier("add-listing-button")
                    }
                }
                .navigationDestination(for: String.self) { listingID in
                    ListingDetailView(listingID: listingID)
                }
        }
        .task(id: session.user?.id) {
            await model.load()
        }
        .fullScreenCover(item: $editor) { request in
            ListingEditorView(model: container.makeListingEditor(for: request)) { saved in
                model.show(saved)
            }
        }
    }

    @ViewBuilder
    private func content(_ model: ListerHomeModel) -> some View {
        if model.listings.isEmpty {
            emptyState(model)
        } else {
            List {
                if case .failed(let message) = model.state {
                    Section {
                        ErrorText(message)
                        Button("Try again") { Task { await model.load() } }
                            .tint(Brand.magenta)
                    }
                }
                Section {
                    ForEach(model.listings) { listing in
                        NavigationLink(value: listing.id) {
                            ListingRow(listing: listing)
                        }
                    }
                    if model.canLoadMore {
                        Button("Show more") { Task { await model.loadMore() } }
                            .tint(Brand.magenta)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await model.load() }
        }
    }

    @ViewBuilder
    private func emptyState(_ model: ListerHomeModel) -> some View {
        VStack(spacing: 16) {
            Spacer()
            switch model.state {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                ErrorText(message)
                Button("Try again") { Task { await model.load() } }
                    .buttonStyle(SecondaryButtonStyle())
            case .loaded:
                Image(systemName: "key.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Brand.orange)
                    .accessibilityHidden(true)
                Text("Your room, their quarter.")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(Brand.ink)
                Text("Post your place and choose who takes it over. Only students who pass your filters will see it.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.ink)
                Button("Post your place") { editor = .new }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

@MainActor
struct ListingRow: View {
    let listing: Listing

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.title)
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
                    .lineLimit(1)
                Text([listing.rentCents.map { "\(Money.dollars($0))/mo" }, listing.dateSummary]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Brand.ink.opacity(0.75))
            }
            Spacer(minLength: 0)
            StatusChip(status: listing.status)
        }
        .padding(.vertical, 4)
    }

    private var thumbnail: some View {
        Group {
            if let address = listing.photos.first?.url, let url = URL(string: address) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Brand.cream
                    }
                }
            } else {
                ZStack {
                    Brand.cream
                    Image(systemName: "house")
                        .foregroundStyle(Brand.ink.opacity(0.4))
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// One of the lister's listings, with what they can do next.
@MainActor
struct ListingDetailView: View {
    let listingID: String
    @Environment(AppContainer.self) private var container
    @State private var editor: EditorRequest?
    @State private var isConfirmingFilled = false

    var body: some View {
        let model = container.listerHome
        Group {
            if let listing = model.listings.first(where: { $0.id == listingID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            StatusChip(status: listing.status)
                            Spacer()
                        }
                        if let address = listing.address {
                            Label(address, systemImage: "mappin.and.ellipse")
                                .font(.subheadline)
                                .foregroundStyle(Brand.ink)
                            Text("Only you see the exact address. Renters see a point about 150 meters away until you match.")
                                .font(.footnote)
                                .foregroundStyle(Brand.ink.opacity(0.7))
                        }
                        ListingCardView(listing: listing)
                        actions(listing, model: model)
                    }
                    .padding(20)
                }
                .confirmationDialog(
                    "Mark this listing as filled?",
                    isPresented: $isConfirmingFilled,
                    titleVisibility: .visible
                ) {
                    Button("Mark as filled") {
                        Task { await model.setStatus(.filled, for: listing) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("It disappears from every deck and can't be reopened.")
                }
            } else {
                ContentUnavailableView("Listing not found", systemImage: "house")
            }
        }
        .background(Brand.cream)
        .navigationTitle("Listing")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.clearActionMessage() }
        .fullScreenCover(item: $editor) { request in
            ListingEditorView(model: container.makeListingEditor(for: request)) { saved in
                model.show(saved)
            }
        }
    }

    @ViewBuilder
    private func actions(_ listing: Listing, model: ListerHomeModel) -> some View {
        let busy = model.busyListingID == listing.id
        VStack(spacing: 12) {
            if let message = model.actionMessage {
                ErrorText(message)
            }
            switch listing.status {
            case .draft:
                Button("Continue editing") { editor = .edit(listing) }
                    .buttonStyle(PrimaryButtonStyle())
            case .active:
                Button("Edit") { editor = .edit(listing) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Pause") { Task { await model.setStatus(.paused, for: listing) } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy)
                Button("Mark as filled") { isConfirmingFilled = true }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(busy)
            case .paused, .expired:
                Button(listing.status == .paused ? "Make it live again" : "Publish again") {
                    Task { await model.setStatus(.active, for: listing) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)
                Button("Edit") { editor = .edit(listing) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Mark as filled") { isConfirmingFilled = true }
                    .buttonStyle(LinkButtonStyle())
                    .disabled(busy)
            case .filled:
                Text("Filled. Nice work.")
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
            }
        }
    }
}

#Preview("My listings") {
    ListerHomeView()
        .previewEnvironment()
}

#Preview("Listing") {
    let container = AppContainer.preview()
    container.listerHome.show(PreviewData.listing)
    return NavigationStack {
        ListingDetailView(listingID: PreviewData.listing.id)
    }
    .environment(container)
    .environment(container.session)
}
