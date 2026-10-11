import SwiftUI

struct MapPlaceholderView: View {
    var body: some View {
        PlaceholderScreen(
            title: "Map",
            systemImage: "map",
            note: "Drop a pin, set a radius, and see listings around it. Arrives in phase 6."
        )
    }
}

#Preview {
    MapPlaceholderView()
}
