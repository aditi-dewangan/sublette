import SwiftUI

/// The bar at the top of every screen: the app name and the Renter / Lister switch.
/// Its color is the current mode's accent.
struct ModeHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        HStack(spacing: 12) {
            Text("Sublette")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(appState.mode.textOnAccent)
            Spacer()
            Picker("Mode", selection: $appState.mode) {
                ForEach(AppMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .accessibilityIdentifier("mode-switch")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(appState.mode.accent)
        .animation(.easeInOut(duration: 0.2), value: appState.mode)
    }
}

#Preview("Renter") {
    ModeHeader()
        .environment(AppState(mode: .renter))
}

#Preview("Lister") {
    ModeHeader()
        .environment(AppState(mode: .lister))
}
