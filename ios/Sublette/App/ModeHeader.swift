import SwiftUI

/// The bar at the top of every screen: the app name and the Renter / Lister switch.
/// Its color is the current mode's accent.
@MainActor
struct ModeHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Text("Sublette")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(appState.mode.textOnAccent)
            Spacer()
            Picker("Mode", selection: modeBinding) {
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
        // Yellow and orange stay light in dark mode, so their controls do too.
        .environment(\.colorScheme, .light)
        .animation(.easeInOut(duration: 0.2), value: appState.mode)
    }

    private var modeBinding: Binding<AppMode> {
        Binding(
            get: { appState.mode },
            set: { appState.setMode($0) }
        )
    }
}

#Preview("Renter") {
    ModeHeader()
        .environment(AppState(preferences: .ephemeral(), mode: .renter))
}

#Preview("Lister") {
    ModeHeader()
        .environment(AppState(preferences: .ephemeral(), mode: .lister))
}
