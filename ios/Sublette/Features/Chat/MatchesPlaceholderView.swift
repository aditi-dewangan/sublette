import SwiftUI

struct MatchesPlaceholderView: View {
    var body: some View {
        PlaceholderScreen(
            title: "Matches",
            systemImage: "bubble.left.and.bubble.right",
            note: "Chats open here when both sides say yes. Arrives in phase 7."
        )
    }
}

#Preview {
    MatchesPlaceholderView()
}
