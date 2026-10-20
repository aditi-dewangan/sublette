import SwiftUI

/// A labelled form row: the label, the control, and an error under it if there is one.
struct FormField<Content: View>: View {
    private let label: String
    private let hint: String?
    private let error: String?
    private let content: () -> Content

    init(
        _ label: String,
        hint: String? = nil,
        error: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.hint = hint
        self.error = error
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
            content()
            if let error {
                ErrorText(error)
            } else if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Brand.ink.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An error message under a field or above a button.
struct ErrorText: View {
    private let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Brand.accentText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Error: \(message)")
    }
}

extension View {
    /// The look of every text field: white, rounded, ink text.
    func brandField() -> some View {
        self
            .font(.body)
            .foregroundStyle(Brand.ink)
            .tint(Brand.accentText)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Brand.ink.opacity(0.12), lineWidth: 1)
            )
    }
}

/// Two choices side by side, for answers such as "Do you smoke?".
struct YesNoPicker: View {
    @Binding var selection: Bool?
    var yesTitle = "Yes"
    var noTitle = "No"

    var body: some View {
        HStack(spacing: 10) {
            choice(noTitle, value: false)
            choice(yesTitle, value: true)
        }
    }

    private func choice(_ title: String, value: Bool) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Brand.textOnYellow : Brand.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    isSelected ? Brand.yellow : Brand.card,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Brand.ink.opacity(isSelected ? 0.6 : 0.12), lineWidth: isSelected ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    VStack(spacing: 20) {
        FormField("First name", error: "This can't be empty.") {
            TextField("Aditi", text: .constant(""))
                .brandField()
        }
        FormField("Do you smoke?", hint: "Listers can choose non-smokers only.") {
            YesNoPicker(selection: .constant(false))
        }
    }
    .padding()
    .background(Brand.cream)
}
