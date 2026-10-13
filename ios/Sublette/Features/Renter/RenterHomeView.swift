import SwiftUI

/// The first tab in Renter mode. Until the deck arrives (phase 5) it shows the
/// renter's search, and asks a new renter to set one up.
@MainActor
struct RenterHomeView: View {
    @Environment(AppContainer.self) private var container
    @Environment(SessionModel.self) private var session
    @State private var editing: PreferencesEditorModel.Step?

    private var search: RenterSearchModel { container.renterSearch }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.cream)
        .refreshable { await search.load() }
        .task(id: session.user?.id) {
            guard let userID = session.user?.id else {
                return
            }
            search.prepare(for: userID)
            if search.profile == nil {
                await search.load()
            }
        }
        .sheet(item: $editing) { step in
            PreferencesFlowView(model: container.makePreferencesEditor(startAt: step)) { saved in
                search.show(saved)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = search.state {
            ErrorText(message)
            Button("Try again") { Task { await search.load() } }
                .buttonStyle(SecondaryButtonStyle())
        }
        if let profile = search.profile {
            if profile.complete {
                summary(profile)
            } else {
                setUp
            }
        } else if search.state == .loading || search.state == .idle {
            ProgressView()
                .tint(Brand.magenta)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        }
    }

    private var setUp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Brand.magenta)
                .accessibilityHidden(true)
            Text("What are you looking for?")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)
            Text("Your dates, budget, must-haves and the area you want. It takes about a minute, and you can change it any time.")
                .font(.body)
                .foregroundStyle(Brand.ink)
            Button("Set up your search") { editing = .dates }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("set-up-search-button")
        }
    }

    private func summary(_ profile: RenterProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your search")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.ink)

            VStack(alignment: .leading, spacing: 12) {
                row("calendar", RenterSummary.dates(profile), step: .dates)
                row("dollarsign.circle", RenterSummary.budget(profile), step: .budget)
                row("checklist", RenterSummary.mustHaves(profile), step: .preferences)
                row("mappin.and.ellipse", RenterSummary.area(profile), step: .area)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text("Listings to swipe on arrive in the next update.")
                .font(.footnote)
                .foregroundStyle(Brand.ink.opacity(0.7))
        }
    }

    private func row(_ icon: String, _ text: String, step: PreferencesEditorModel.Step) -> some View {
        Button {
            editing = step
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(text)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(Brand.ink)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit")
    }
}

/// Short sentences about a renter's search.
enum RenterSummary {
    static func dates(_ profile: RenterProfile) -> String {
        guard let start = CalendarDate.date(from: profile.startDate),
              let end = CalendarDate.date(from: profile.endDate)
        else {
            return "No dates yet"
        }
        let style = Date.FormatStyle().month(.abbreviated).day()
        let flexible = profile.flexibilityDays > 0 ? ", ± \(profile.flexibilityDays) days" : ""
        return "\(start.formatted(style)) – \(end.formatted(style))\(flexible)"
    }

    static func budget(_ profile: RenterProfile) -> String {
        profile.maxRentCents.map { "Up to \(Money.dollars($0)) a month" } ?? "No budget yet"
    }

    static func mustHaves(_ profile: RenterProfile) -> String {
        let musts = profile.mustHaves
        return musts.isEmpty ? "No must-haves" : "Must have: " + musts.joined(separator: ", ")
    }

    static func area(_ profile: RenterProfile) -> String {
        guard let pin = profile.pin else {
            return "No area yet"
        }
        return "Within \(Distance.miles(pin.radiusM)) of your pin"
    }
}

#Preview("Set up") {
    RenterHomeView()
        .previewEnvironment()
}
