import SwiftUI

@main
struct SubletteApp: App {
    @State private var appState: AppState
    @State private var serverStatus: ServerStatusModel

    init() {
        let configuration = AppConfiguration.load()
        let client = APIClient(baseURL: configuration.apiBaseURL)
        _appState = State(initialValue: AppState())
        _serverStatus = State(
            initialValue: ServerStatusModel(health: client, configuration: configuration)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(serverStatus)
                // The palette is designed for a light background. Dark mode arrives in phase 9.
                .preferredColorScheme(.light)
        }
    }
}
