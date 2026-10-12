import SwiftUI

/// The main action on a screen: a magenta capsule with white text.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Brand.textOnMagenta)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Brand.magenta, in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        }
    }
}

/// A quieter action: ink text in an ink outline.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Brand.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Capsule().stroke(Brand.ink.opacity(0.35), lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// A text-only action, such as "Change email".
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.magenta)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

#Preview {
    VStack(spacing: 16) {
        Button("Send code") {}
            .buttonStyle(PrimaryButtonStyle())
        Button("Send code") {}
            .buttonStyle(PrimaryButtonStyle())
            .disabled(true)
        Button("Sign out") {}
            .buttonStyle(SecondaryButtonStyle())
        Button("Change email") {}
            .buttonStyle(LinkButtonStyle())
    }
    .padding()
    .background(Brand.cream)
}
