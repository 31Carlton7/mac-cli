import XCTest
@testable import MailModule

/// Synthetic messages written after the shape of real one-time-code mail.
/// Every sender, address and code here is made up.
final class VerificationCodesTests: XCTestCase {
    func codes(_ subject: String, _ body: String) -> [MailExtraction.Code] {
        VerificationCodes.find(subject: subject, body: body)
    }

    func assertTop(_ subject: String, _ body: String, _ expected: String,
                   _ confidence: MailExtraction.Code.Confidence = .high,
                   file: StaticString = #filePath, line: UInt = #line) {
        let found = codes(subject, body)
        XCTAssertEqual(found.first?.code, expected, "\(found)", file: file, line: line)
        XCTAssertEqual(found.first?.confidence, confidence, "\(found)", file: file, line: line)
    }

    func assertNone(_ subject: String, _ body: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = codes(subject, body)
        XCTAssertTrue(found.isEmpty, "\(found)", file: file, line: line)
    }

    // MARK: - Real-world shapes

    func testGitHubDeviceVerification() {
        assertTop("[GitHub] Please verify your device", """
            Hey octo-example!

            A sign in attempt requires further verification because we did not recognize your device. \
            To complete the sign in, enter the verification code on the unrecognized device.

            Device: Safari on macOS
            Verification code: 40917263

            If you did not attempt to sign in to your account, your password may be compromised. \
            Visit https://github.com/settings/security to create a new, strong password for your GitHub account.

            Thanks,
            The GitHub Team
            """, "40917263")
    }

    func testGoogleCodeOnItsOwnLine() {
        assertTop("Your Google verification code", """
            Google

            Verify your email

            Google received a request to use example.person@example.com as a recovery email for Google Account \
            someone@example.com.

            Use this code to finish setting up this recovery email:

            582034

            This code will expire in 24 hours.

            If you don’t recognize someone@example.com, you can safely ignore this email.
            """, "582034")
    }

    func testGoogleSMSShapeDropsThePrefix() {
        assertTop("", "G-731052 is your Google verification code.", "731052")
    }

    func testAppleAccountCodeAfterAHeading() {
        assertTop("Verify your Apple Account email address", """
            Verification code

            Enter the following code to verify your email address:

            318406

            Verification codes expire after three hours.

            If you didn't make this change or if you believe an unauthorized person has accessed your account, \
            go to iforgot.apple.com to reset your password.

            Apple Support
            """, "318406")
    }

    func testMicrosoftSecurityCodeWithAccountMasking() {
        let found = codes("Microsoft account security code", """
            Microsoft account

            Security code

            Please use the following security code for the Microsoft account ex*****@example.com.

            Security code: 4072915

            If you don't recognize the Microsoft account ex*****@example.com, you can click \
            https://account.live.com/dp?ft=Abc123 to remove your email address from that account.

            Thanks,
            The Microsoft account team
            """)
        XCTAssertEqual(found.map(\.code), ["4072915"])
        XCTAssertEqual(found.first?.confidence, .high)
        XCTAssertEqual(found.first?.context, "Security code: 4072915")
    }

    func testBankOneTimePasscodeIgnoresAmountsAndPhone() {
        let found = codes("Your one-time passcode", """
            Example Bank

            Your one-time passcode is 66104382. It expires in 10 minutes.

            We will never call you to ask for this passcode. Never share it with anyone, including us.

            You requested this code to approve a payment of $1,250.00 to ACME STORE 2291.

            Questions? Call us at 1-800-555-0142 or (800) 555 0199.
            """)
        XCTAssertEqual(found.map(\.code), ["66104382"])
        XCTAssertEqual(found.first?.confidence, .high)
    }

    func testSlackConfirmationCodeKeepsItsHyphen() {
        assertTop("Slack confirmation code: 396-218", """
            Confirm your email address

            Your confirmation code is below — enter it in your open browser window and we'll help you get signed in.

            396-218

            If you didn't request this email, there's nothing to worry about — you can safely ignore it.
            """, "396-218")
        XCTAssertEqual(codes("Slack confirmation code: 396-218", "396-218").count, 1, "one entry for subject and body")
    }

    func testAlphanumericCodeWithHyphen() {
        assertTop("Your sign-in code", "Enter this sign-in code to continue: K7QD-29XM\nIt expires in 15 minutes.", "K7QD-29XM")
    }

    func testCodeBeforeItsCue() {
        assertTop("", "481206 is your Example login code. Don't share it.", "481206")
    }

    func testNonEnglishCues() {
        assertTop("Tu código de verificación", "Tu código de verificación es 204815. Caduca en 10 minutos.", "204815")
        assertTop("Ihr Bestätigungscode", "Ihr Bestätigungscode lautet: 773190\nEr ist 10 Minuten gültig.", "773190")
        assertTop("Votre code de vérification", "Votre code de vérification est : 615027", "615027")
        assertTop("", "您的验证码是：380492，5分钟内有效。", "380492")
    }

    func testTwoFactorInHTMLConvertedBody() {
        // What HTMLText makes of a table-laid-out code email.
        let body = HTMLText.plainText("""
            <html><head><style>.code{color:#1A2B3C;font-size:28px}</style></head>
            <body><table><tr><td style="color:#334455">Your two-factor authentication code</td></tr>
            <tr><td class="code"><strong>905513</strong></td></tr>
            <tr><td>This code expires in 5 minutes. <a href="https://example.com/help?ref=20241014">Help</a></td></tr>
            </table></body></html>
            """)
        assertTop("Two-factor authentication", body, "905513")
    }

    func testRanksTheCuedCodeAboveAWeakerOne() {
        let found = codes("Your verification code", """
            Your verification code is 552901.

            Reference code 8841 was attached to your support request.
            """)
        XCTAssertEqual(found.first?.code, "552901")
        XCTAssertEqual(found.first?.confidence, .high)
    }

    // MARK: - False positives

    func testYearsAreNotCodes() {
        assertNone("Your code", "Your verification code was sent on 14 October 2026. © 2026 Example Inc.")
    }

    func testAYearRightAfterItsCueStillCounts() {
        XCTAssertEqual(codes("", "Verification code: 2048").map(\.code), ["2048"])
    }

    func testPhoneNumbersAreNotCodes() {
        assertNone("Verify your account", """
            To verify your account call 555 0142 8890 or +1 (415) 555-2671 or 800.555.0199.
            Our verification line is 1-800-555-0142.
            """)
    }

    func testPricesAreNotCodes() {
        assertNone("Your code", "Use the code at checkout. Total $1299 or 1299 USD, €4500, £2000.")
    }

    func testOrderNumbersWithoutACueAreNotCodes() {
        assertNone("Your order has shipped", """
            Order 12345678 shipped on 2026-10-14. Tracking 9400111202555842. Invoice #88213471.
            """)
    }

    func testOrderNumberBesideACueIsDropped() {
        XCTAssertEqual(codes("", "Your verification code is 638201. Order number 77310442.").map(\.code), ["638201"])
    }

    func testLabelledNumbersNearAStrongCueAreDropped() {
        assertNone("Verify your account", "Verify your account 55190284 by entering the code we sent.")
        assertNone("Your trip", "Confirmation number: U7KD2Q9X. Verify your booking at the counter.")
    }

    func testMeetingPasscodesAreNotHighConfidence() {
        let found = codes("Invitation: Weekly sync", """
            Join Zoom Meeting
            https://example.zoom.us/j/95502480200?pwd=abc

            Meeting ID: 955 0248 0200
            Passcode: 741779
            """)
        XCTAssertEqual(found.map(\.code), ["741779"])
        XCTAssertNotEqual(found.first?.confidence, .high)
    }

    func testCSSColoursAreNotCodes() {
        assertNone("Verify your email", "color: #1A2B3C; background:#FF5733; verification code style #A1B2C3")
    }

    func testPromoCodesAreNotCodes() {
        assertNone("20% off this weekend", "Use promo code SAVE20 at checkout. Discount code FALL2026 ends Sunday.")
    }

    func testCodesOfferedForADiscountAreNotCodes() {
        assertNone("This weekend only", "Use code SAVE20 for 20% off. Enter code FALL2026 at checkout.")
    }

    func testZipAndQRCodesAreNotCues() {
        assertNone("Your delivery", "Zip code 94107. Scan the QR code 4412 at the locker.")
    }

    func testCodeOfConductIsNotACue() {
        assertNone("Welcome", "Please read our code of conduct, version 2041.")
    }

    func testDigitsInsideLinksAndAddressesAreNotCodes() {
        assertNone("Verify your email", """
            Verify your email: https://example.com/verify?token=830152&user=44718
            Questions: support-830152@example.com
            """)
    }

    func testCapitalWordsAreNotCodes() {
        assertNone("SECURITY CODE NOTICE", "Your SECURITY CODE NOTICE: HTTPS VERIFY")
    }

    func testNoCueNoCodes() {
        assertNone("Weekly digest", "Top stories: 482913 readers, 204815 views, room 4412.")
    }
}
