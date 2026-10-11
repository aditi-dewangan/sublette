import SwiftUI

struct ProfilePlaceholderView: View {
    var body: some View {
        PlaceholderScreen(
            title: "Profile",
            systemImage: "person.crop.circle",
            note: "Sign up with a .edu email and build your profile. Arrives in phase 1."
        )
    }
}

#Preview {
    ProfilePlaceholderView()
}
