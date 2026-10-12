import SwiftUI

/// "Verified" with the school's name. Shown on every profile.
struct VerifiedBadge: View {
    let schoolName: String

    var body: some View {
        Label {
            Text("Verified · \(schoolName)")
        } icon: {
            Image(systemName: "checkmark.seal.fill")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Brand.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Brand.yellow, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verified student at \(schoolName)")
    }
}

/// A round profile photo, or a placeholder when there is none or it can't load.
struct AvatarView: View {
    let urlString: String?
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        // Still loading, or storage can't be reached.
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Brand.ink.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Color.white
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(Brand.ink.opacity(0.3))
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        AvatarView(urlString: nil)
        VerifiedBadge(schoolName: "University of Washington")
    }
    .padding()
    .background(Brand.cream)
}
