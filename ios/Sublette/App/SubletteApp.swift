import SwiftUI

@main
struct SubletteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
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
                    appDelegate.notifications = container.notifications
                    appDelegate.openChatID = { [weak container] in container?.matchesModel.activeChat?.match.id }
                    await container.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Task { await container.appBecameActive() }
                    case .background: container.appWentToBackground()
                    default: break
                    }
                }
        }
    }
}
