import SwiftUI

/// A stand-in for a screen that a later phase builds.
struct PlaceholderScreen<Extra: View>: View {
    private let title: String
    private let systemImage: String
    private let note: String
    private let extra: () -> Extra

    init(
        title: String,
        systemImage: String,
        note: String,
        @ViewBuilder extra: @escaping () -> Extra
    ) {
        self.title = title
        self.systemImage = systemImage
        self.note = note
        self.extra = extra
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Brand.magenta)
                    .padding(.top, 40)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(Brand.ink)
                Text(note)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Brand.ink)
                extra()
                    .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.cream)
    }
}

extension PlaceholderScreen where Extra == EmptyView {
    init(title: String, systemImage: String, note: String) {
        self.init(title: title, systemImage: systemImage, note: note) { EmptyView() }
    }
}

#Preview {
    PlaceholderScreen(title: "Map", systemImage: "map", note: "Pins arrive in phase 6.")
}
