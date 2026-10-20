import XCTest
@testable import Sublette

/// The Assistant screen (phase 10).
@MainActor
final class AssistantTests: XCTestCase {
    private func makeModel(_ api: StubAssistantAPI, deck: StubDeckAPI = StubDeckAPI()) -> AssistantModel {
        let outbox = SwipeOutbox(api: deck, preferences: .ephemeral())
        outbox.prepare(for: "user-1")
        return AssistantModel(api: api, outbox: outbox, makeSwipeID: { "swipe-1" })
    }

    func testTheScreenShowsOnlyWhenTheServerSaysSo() async {
        let api = StubAssistantAPI()
        let model = makeModel(api)
        XCTAssertFalse(model.isEnabled, "hidden until the server answers")

        await model.refreshStatus()
        XCTAssertTrue(model.isEnabled)

        api.statusResult = .success(AssistantStatus(enabled: false, label: "x"))
        await model.refreshStatus()
        XCTAssertFalse(model.isEnabled, "turned off on the server, gone without an app update")
    }

    func testOfflineTheLastAnswerStands() async {
        let api = StubAssistantAPI()
        let model = makeModel(api)
        await model.refreshStatus()

        api.statusResult = .failure(APIError.unreachable)
        await model.refreshStatus()

        XCTAssertTrue(model.isEnabled)
    }

    func testAskingShowsTheSuggestionsWithTheirReasons() async {
        let api = StubAssistantAPI()
        api.answerResult = .success(AssistantAnswer(
            understood: PreferenceChanges(maxRentCents: 120_000),
            summary: "Under $1,200",
            items: [AssistantItem(item: Fixture.deckItem("l1"), why: "Close and cheap.")],
            generatedBy: "ai",
            label: "Generated automatically."
        ))
        let model = makeModel(api)
        model.message = "  under 1200  "

        await model.ask()

        XCTAssertEqual(api.asked, ["under 1200"])
        XCTAssertEqual(model.state, .answered)
        XCTAssertEqual(model.answer?.items.map(\.why), ["Close and cheap."])
    }

    func testAnEmptyMessageAsksNothing() async {
        let api = StubAssistantAPI()
        let model = makeModel(api)
        model.message = "   "

        await model.ask()

        XCTAssertEqual(api.asked, [])
    }

    func testTurnedOffWhileOpenHidesIt() async {
        let api = StubAssistantAPI()
        api.answerResult = .failure(Fixture.serverError(403, "assistant_off", "The assistant isn't available right now."))
        let model = makeModel(api)
        await model.refreshStatus()
        model.message = "anything"

        await model.ask()

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.state, .failed("The assistant isn't available right now."))
    }

    func testLikingASuggestionIsASwipeAndLeavesTheDeck() async {
        let deck = StubDeckAPI()
        let model = makeModel(StubAssistantAPI(), deck: deck)
        var forgotten: [String] = []
        model.onLiked = { forgotten.append($0) }
        let suggestion = AssistantItem(item: Fixture.deckItem("l1"), why: "x")

        await model.like(suggestion)
        await model.like(suggestion)

        XCTAssertEqual(deck.swipes.map(\.listingId), ["l1"], "liked once")
        XCTAssertEqual(deck.swipes.first?.action, .like)
        XCTAssertEqual(forgotten, ["l1"])
    }

    func testSavingTheUnderstoodPreferences() async {
        let api = StubAssistantAPI()
        let changes = PreferenceChanges(maxRentCents: 90_000)
        api.answerResult = .success(AssistantAnswer(understood: changes, summary: "", items: [], generatedBy: "sublette", label: ""))
        let model = makeModel(api)
        var saved: [PreferenceChanges] = []
        model.saveChanges = { saved.append($0); return true }
        model.message = "under 900"
        await model.ask()

        await model.saveUnderstood()

        XCTAssertEqual(saved, [changes])
        XCTAssertTrue(model.savedPreferences)
    }

    func testChangesMergeIntoTheSearch() {
        let form = RenterProfileForm(
            startDate: "2027-01-10", endDate: "2027-03-10", flexibilityDays: 3, maxRentCents: 100_000,
            preferences: [
                Preference(field: .furnished, value: .yes, importance: .nice),
                Preference(field: .parking, value: .yes, importance: .must),
            ],
            pin: SearchPin(latitude: 47.6, longitude: -122.3, radiusM: 4_828)
        )
        let changes = PreferenceChanges(
            startDate: "2027-06-01", endDate: "2027-08-31", maxRentCents: nil, radiusM: 999_999,
            preferences: [Preference(field: .furnished, value: .yes, importance: .must)]
        )

        let merged = form.applying(changes)

        XCTAssertEqual(merged.startDate, "2027-06-01")
        XCTAssertEqual(merged.maxRentCents, 100_000, "not mentioned, so kept")
        XCTAssertEqual(merged.pin?.radiusM, SearchPin.maxRadiusM)
        XCTAssertEqual(merged.flexibilityDays, 3)
        XCTAssertEqual(merged.preferences.first { $0.field == .furnished }?.importance, .must)
        XCTAssertEqual(merged.preferences.first { $0.field == .parking }?.importance, .must)
        XCTAssertEqual(merged.preferences.count, 2)
    }

    func testTheServersAnswerDecodes() throws {
        let json = #"""
        {"understood": {"start_date": "2027-06-01", "end_date": "2027-08-31", "max_rent_cents": 120000,
          "radius_m": null, "preferences": [{"field": "space_type", "value": ["private_room"], "importance": "must"}]},
         "summary": "Private room · under $1,200", "items": [], "generated_by": "ai",
         "label": "Suggestions are generated automatically and drawn only from listings on Sublette."}
        """#
        let answer = try APIClient.makeDecoder().decode(AssistantAnswer.self, from: Data(json.utf8))

        XCTAssertEqual(answer.understood.preferences.first?.value, .spaceTypes([.privateRoom]))
        XCTAssertEqual(answer.generatedBy, "ai")
        XCTAssertEqual(Endpoint.assistantQuery.path, "/v1/assistant/query")
    }
}

/// The assistant's real server answers, from docs/contract/samples.
final class AssistantContractTests: XCTestCase {
    func testSamplesDecode() throws {
        let decoder = APIClient.makeDecoder()
        let status = try decoder.decode(AssistantStatus.self, from: Fixture.sample("assistant_status"))
        let answer = try decoder.decode(AssistantAnswer.self, from: Fixture.sample("assistant_answer"))

        XCTAssertTrue(status.enabled)
        XCTAssertEqual(answer.items.count, 1)
        XCTAssertFalse(answer.items[0].why.isEmpty)
        XCTAssertEqual(answer.understood.maxRentCents, 120_000)
        XCTAssertTrue(answer.understood.preferences.contains { $0.field == .parking && $0.importance == .nice })
        XCTAssertTrue(answer.label.contains("drawn only from listings on Sublette"))
    }
}
