import XCTest
@testable import Sublette

@MainActor
final class OnboardingModelTests: XCTestCase {
    private func makeModel(_ test: TestSession) -> OnboardingModel {
        OnboardingModel(api: test.api, session: test.session, now: { Fixture.now })
    }

    // MARK: - Email step

    func testAnEmailThatDoesNotEndInEduIsRefusedWithAClearMessage() async {
        let test = TestSession()
        let model = makeModel(test)
        model.email = "aditi@gmail.com"

        await model.submitEmail()

        XCTAssertEqual(model.errorMessage, "Sublette is for students. Use your school email ending in .edu.")
        XCTAssertEqual(model.step, .email)
        XCTAssertEqual(test.api.requestedCodes, [], "The server is not asked about an obviously wrong address")
    }

    func testThingsThatAreNotEmailsAreRefusedBeforeAskingTheServer() async {
        let test = TestSession()
        let model = makeModel(test)

        for bad in ["", "   ", "aditi", "@uw.edu", "aditi@", "a b@uw.edu", "aditi@@uw.edu"] {
            model.email = bad
            await model.submitEmail()
            XCTAssertEqual(model.errorMessage, OnboardingModel.invalidEmailMessage, "for \"\(bad)\"")
        }
        XCTAssertEqual(test.api.requestedCodes, [])
    }

    func testLookalikeDomainsAreNotMistakenForEdu() {
        let model = makeModel(TestSession())

        for bad in ["a@uw.edu.evil.com", "a@student.unimelb.edu.au", "a@fakeedu.com"] {
            model.email = bad
            XCTAssertEqual(model.localEmailProblem(), OnboardingModel.notEduMessage, bad)
        }
    }

    func testEmailsFromTwoDifferentSchoolsBothWork() async {
        for address in ["aditi@uw.edu", "sam@northeastern.edu", "lee@cs.washington.edu"] {
            let test = TestSession()
            let model = makeModel(test)
            model.email = address

            await model.submitEmail()

            XCTAssertEqual(model.step, .code, address)
            XCTAssertNil(model.errorMessage, address)
        }
    }

    func testTheEmailIsTrimmedAndLowercasedBeforeItIsSent() async {
        let test = TestSession()
        let model = makeModel(test)
        model.email = "  Aditi@UW.edu \n"

        await model.submitEmail()

        XCTAssertEqual(test.api.requestedCodes, ["aditi@uw.edu"])
        XCTAssertEqual(model.sentTo, "aditi@uw.edu")
        XCTAssertEqual(model.step, .code)
        XCTAssertFalse(model.isWorking)
    }

    func testTheServersRefusalIsShown() async {
        let test = TestSession()
        test.api.requestCodeResult = .failure(
            Fixture.serverError(403, "domain_blocked", "Sign-ups from that email domain aren't open.")
        )
        let model = makeModel(test)
        model.email = "old@alumni.uw.edu"

        await model.submitEmail()

        XCTAssertEqual(model.errorMessage, "Sign-ups from that email domain aren't open.")
        XCTAssertEqual(model.step, .email)
    }

    // MARK: - Dependency unavailable: the server and the email provider

    func testServerDownShowsAMessageAndAllowsAnotherTry() async {
        let test = TestSession()
        test.api.requestCodeResult = .failure(APIError.unreachable)
        let model = makeModel(test)
        model.email = "aditi@uw.edu"

        await model.submitEmail()

        XCTAssertEqual(model.errorMessage, "Can't reach Sublette right now. Check your connection and try again.")
        XCTAssertEqual(model.step, .email)
        XCTAssertFalse(model.isWorking)

        test.api.requestCodeResult = .success(CodeRequestResponse(expiresIn: 600, resendIn: 30))
        await model.submitEmail()

        XCTAssertEqual(model.step, .code)
        XCTAssertNil(model.errorMessage)
    }

    func testEmailProviderDownShowsTheServersMessage() async {
        let test = TestSession()
        test.api.requestCodeResult = .failure(
            Fixture.serverError(503, "email_unavailable", "We couldn't send your code just now. Try again in a minute.")
        )
        let model = makeModel(test)
        model.email = "aditi@uw.edu"

        await model.submitEmail()

        XCTAssertEqual(model.errorMessage, "We couldn't send your code just now. Try again in a minute.")
        XCTAssertEqual(model.step, .email)
    }

    func testServerDownWhileVerifyingKeepsTheStudentOnTheCodeStep() async {
        let test = TestSession()
        let model = makeModel(test)
        model.email = "aditi@uw.edu"
        await model.submitEmail()
        test.api.verifyResult = .failure(APIError.unreachable)
        model.code = "123456"

        await model.submitCode()

        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(model.errorMessage, APIError.unreachable.userMessage)
        XCTAssertEqual(test.session.state, .restoring, "Nobody was signed in")
    }

    // MARK: - Code step

    func testTheRightCodeSignsIn() async {
        let test = TestSession()
        test.api.verifyResult = .success(Fixture.session(user: Fixture.newUser))
        let model = makeModel(test)
        model.email = "aditi@uw.edu"
        await model.submitEmail()
        model.code = "482913"

        await model.submitCode()

        XCTAssertEqual(test.api.verifications, ["aditi@uw.edu 482913"])
        XCTAssertEqual(test.session.state, .signedIn(Fixture.newUser))
        XCTAssertNotNil(test.store.load())
        // Ready for the next person who signs in on this phone.
        XCTAssertEqual(model.step, .email)
        XCTAssertEqual(model.email, "")
        XCTAssertEqual(model.code, "")
    }

    func testAWrongCodeShowsTheServersMessageAndClearsTheField() async {
        let test = TestSession()
        test.api.verifyResult = .failure(
            Fixture.serverError(400, "code_invalid", "That code isn't right. 4 tries left.")
        )
        let model = makeModel(test)
        model.email = "aditi@uw.edu"
        await model.submitEmail()
        model.code = "000000"

        await model.submitCode()

        XCTAssertEqual(model.errorMessage, "That code isn't right. 4 tries left.")
        XCTAssertEqual(model.code, "")
        XCTAssertEqual(model.step, .code)
        XCTAssertNil(test.store.load())
    }

    func testAnExpiredOrLockedCodeTellsTheStudentToRequestANewOne() async {
        for (code, message) in [
            ("code_expired", "That code has expired. Request a new code."),
            ("code_locked", "Too many wrong codes. Request a new code."),
        ] {
            let test = TestSession()
            test.api.verifyResult = .failure(Fixture.serverError(400, code, message))
            let model = makeModel(test)
            model.email = "aditi@uw.edu"
            await model.submitEmail()
            model.code = "123456"

            await model.submitCode()

            XCTAssertEqual(model.errorMessage, message)
            XCTAssertEqual(model.step, .code)
        }
    }

    func testACodeThatIsNotSixDigitsIsNotSent() async {
        let test = TestSession()
        let model = makeModel(test)
        model.email = "aditi@uw.edu"
        await model.submitEmail()

        for bad in ["", "12345", "1234567", "12a456", "12 34"] {
            model.code = bad
            await model.submitCode()
            XCTAssertEqual(model.errorMessage, OnboardingModel.invalidCodeMessage, "for \"\(bad)\"")
        }
        XCTAssertEqual(test.api.verifications, [])
    }

    // MARK: - Resend

    func testResendWaitsForTheServersCooldown() async {
        let test = TestSession()
        let model = makeModel(test)
        model.email = "aditi@uw.edu"
        await model.submitEmail()

        XCTAssertEqual(model.secondsUntilResend(at: Fixture.now), 30)
        XCTAssertEqual(model.secondsUntilResend(at: Fixture.now.addingTimeInterval(29.2)), 1)
        XCTAssertEqual(model.secondsUntilResend(at: Fixture.now.addingTimeInterval(30)), 0)
        XCTAssertEqual(model.secondsUntilResend(at: Fixture.now.addingTimeInterval(600)), 0)

        // The model's clock still says "now", so this resend is too early and is ignored.
        await model.resend()
        XCTAssertEqual(test.api.requestedCodes, ["aditi@uw.edu"])
    }

    func testResendSendsToTheSameAddressOnceAllowed() async {
        let test = TestSession()
        var clock = Fixture.now
        let model = OnboardingModel(api: test.api, session: test.session, now: { clock })
        model.email = "aditi@uw.edu"
        await model.submitEmail()
        model.email = "someone-else@uw.edu"  // editing the field must not redirect the code

        clock = Fixture.now.addingTimeInterval(31)
        await model.resend()

        XCTAssertEqual(test.api.requestedCodes, ["aditi@uw.edu", "aditi@uw.edu"])
        XCTAssertEqual(model.sentTo, "aditi@uw.edu")
    }

    func testChangeEmailGoesBackWithoutLosingTheAddress() async {
        let test = TestSession()
        let model = makeModel(test)
        model.email = "aditi@uw.edu"
        await model.submitEmail()
        model.code = "12"

        model.changeEmail()

        XCTAssertEqual(model.step, .email)
        XCTAssertEqual(model.email, "aditi@uw.edu")
        XCTAssertEqual(model.code, "")
        XCTAssertNil(model.errorMessage)
    }
}
