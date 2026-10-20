import SwiftUI

/// Commute times on each card, to the renter's saved places.
@MainActor
struct CommuteLines: View {
    let listing: Listing
    @Environment(AppContainer.self) private var container

    var body: some View {
        let lines = container.commute.lines(for: listing)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "clock")
                    .font(.footnote.weight(.medium))
            }
        }
        .task(id: listing.id) {
            await container.commute.load(for: listing)
        }
    }
}

/// "Places you go": up to two, such as campus and work. Kept on this phone.
@MainActor
struct PlacesView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Campus"
    @State private var address = ""
    @State private var looking = false
    @State private var problem: String?

    private var model: CommuteModel { container.commute }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.places.isEmpty {
                        Text("No places yet.")
                            .foregroundStyle(Brand.ink.opacity(0.75))
                    }
                    ForEach(model.places) { place in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.headline)
                            Text(place.address).font(.footnote)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { model.remove(place) }
                        }
                    }
                } footer: {
                    Text("Cards show how long it takes to get there by transit or on foot. These places stay on this phone; Sublette's server never sees them.")
                }
                if model.canAddPlace {
                    Section("Add a place") {
                        TextField("Name, such as Campus or Work", text: $name)
                        TextField("Address", text: $address)
                            .textContentType(.fullStreetAddress)
                        if let problem {
                            ErrorText(problem)
                        }
                        Button(looking ? "Finding it…" : "Add") { add() }
                            .disabled(looking || name.trimmed.isEmpty || address.trimmed.isEmpty)
                            .accessibilityIdentifier("add-place")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.cream)
            .navigationTitle("Places you go")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Brand.accentText)
    }

    private func add() {
        looking = true
        problem = nil
        Task {
            do {
                let found = try await container.addressLocator.locate(address.trimmed)
                model.add(SavedPlace(
                    id: UUID().uuidString.lowercased(),
                    name: name.trimmed,
                    address: found.formatted,
                    latitude: found.coordinate.latitude,
                    longitude: found.coordinate.longitude
                ))
                address = ""
                name = model.places.contains { $0.name == "Work" } ? "" : "Work"
            } catch AddressLookupError.notFound {
                problem = "Couldn't find that address. Check it and try again."
            } catch {
                problem = "Maps can't be reached right now. Try again in a moment."
            }
            looking = false
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

#Preview {
    PlacesView()
        .previewEnvironment()
}
