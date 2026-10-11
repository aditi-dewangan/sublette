import XCTest
@testable import Sublette

/// The Phase 0 screen must show a clear state, and stay usable, whatever the server does.
@MainActor
final class ServerStatusModelTests: XCTestCase {
    private func makeModel(
        _ health: StubHealth,
        environment: AppEnvironment = .local
    ) -> ServerStatusModel {
        ServerStatusModel(
            health: health,
            configuration: AppConfiguration(
                environment: environment,
                apiBaseURL: URL(string: "http://localhost:8000")!
            )
        )
    }

    private let healthy = HealthStatus(
        status: "ok",
        version: "0.1.0",
        environment: "local",
        database: .init(reachable: true, postgis: "3.4.2")
    )

    func testStartsIdle() {
        XCTAssertEqual(makeModel(StubHealth(.success(healthy))).state, .idle)
    }

    func testHealthyServer() async {
        let model = makeModel(StubHealth(.success(healthy)))

        await model.refresh()

        XCTAssertEqual(model.state, .healthy(healthy))
        XCTAssertEqual(model.title, "Server is up")
        XCTAssertTrue(model.detail.contains("0.1.0"))
        XCTAssertFalse(model.isLoading)
    }

    func testServerDownShowsUnreachableAndHowToFixItLocally() async {
        let model = makeModel(StubHealth(.failure(APIError.unreachable)))

        await model.refresh()

        XCTAssertEqual(model.state, .unreachable)
        XCTAssertEqual(model.title, "Can't reach the server")
        XCTAssertTrue(model.detail.contains("http://localhost:8000"))
        XCTAssertTrue(model.detail.contains("make dev"))
        XCTAssertFalse(model.isLoading)
    }

    func testServerDownOnStagingDoesNotMentionDeveloperCommands() async {
        let model = makeModel(StubHealth(.failure(APIError.unreachable)), environment: .staging)

        await model.refresh()

        XCTAssertEqual(model.state, .unreachable)
        XCTAssertFalse(model.detail.contains("make dev"))
    }

    func testDatabaseDownShowsTheServerMessage() async {
        let error = APIError.server(
            status: 503,
            code: "database_unreachable",
            message: "The server is running but cannot reach its database.",
            fields: []
        )
        let model = makeModel(StubHealth(.failure(error)))

        await model.refresh()

        XCTAssertEqual(
            model.state,
            .degraded(message: "The server is running but cannot reach its database.")
        )
        XCTAssertEqual(model.title, "Server has a problem")
    }

    func testUnexpectedBodyIsAProblemNotACrash() async {
        let model = makeModel(StubHealth(.failure(APIError.decoding)))

        await model.refresh()

        XCTAssertEqual(model.state, .degraded(message: APIError.decoding.userMessage))
    }

    func testAnyOtherErrorIsTreatedAsUnreachable() async {
        struct Strange: Error {}
        let model = makeModel(StubHealth(.failure(Strange())))

        await model.refresh()

        XCTAssertEqual(model.state, .unreachable)
    }

    func testRecoversWhenTheServerComesBack() async {
        let health = StubHealth(.failure(APIError.unreachable))
        let model = makeModel(health)

        await model.refresh()
        XCTAssertEqual(model.state, .unreachable)

        health.result = .success(healthy)
        await model.refresh()
        XCTAssertEqual(model.state, .healthy(healthy))
    }
}

private final class StubHealth: HealthChecking, @unchecked Sendable {
    var result: Result<HealthStatus, Error>

    init(_ result: Result<HealthStatus, Error>) {
        self.result = result
    }

    func health() async throws -> HealthStatus {
        try result.get()
    }
}
