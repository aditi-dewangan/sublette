import SwiftUI

@main
struct SubletteApp: App {
    @State private var container: AppContainer

    init() {
        _container = State(initialValue: AppContainer.live())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(container)
                .environment(container.appState)
                .environment(container.session)
                .environment(container.serverStatus)
                // The palette is designed for a light background. Dark mode arrives in phase 9.
                .preferredColorScheme(.light)
                .task {
                    await container.start()
                }
        }
    }
}
