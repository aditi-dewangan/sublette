import SwiftUI

/// Phase 0 only: shows what `/health` said, so we can see the app and the server talking.
@MainActor
struct ServerStatusCard: View {
    @Environment(ServerStatusModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .foregroundStyle(Brand.magenta)
                    .accessibilityHidden(true)
                Text(model.title)
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
                Spacer()
                if model.isLoading {
                    ProgressView()
                }
            }
            Text(model.detail)
                .font(.subheadline)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.refresh() }
            } label: {
                Text("Check again")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.textOnMagenta)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Brand.magenta, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading)
            .opacity(model.isLoading ? 0.5 : 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("server-status-card")
        .task {
            // Unit tests launch the whole app as their host. It must not call a real server then.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
                return
            }
            await model.refresh()
        }
    }

    private var symbolName: String {
        switch model.state {
        case .idle, .loading: return "arrow.triangle.2.circlepath"
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unreachable: return "wifi.slash"
        }
    }
}

#Preview("Healthy") {
    ServerStatusCard()
        .environment(ServerStatusModel.preview(.healthy(ServerStatusModel.previewHealthy)))
        .padding()
        .background(Brand.cream)
}

#Preview("Server down") {
    ServerStatusCard()
        .environment(ServerStatusModel.preview(.unreachable))
        .padding()
        .background(Brand.cream)
}
