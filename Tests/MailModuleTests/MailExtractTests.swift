import XCTest
import Core
@testable import MailModule

/// Links, List-Unsubscribe targets and the unsubscribe decision, on
/// synthetic messages. No test touches the network or Mail.app.
final class MailExtractTests: XCTestCase {
    func message(_ rfc822: String) throws -> EmlxMessage {
        let text = rfc822.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        return try EmlxMessage(rfc822: ArraySlice(Array(text.utf8)), isPartial: false, flags: nil)
    }

    let htmlOnly = """
        From: Example Shop <news@shop.example>
        To: me@example.com
        Subject: Fall sale
        Message-ID: <sale-1@shop.example>
        List-Unsubscribe: <mailto:leave@lists.shop.example?subject=unsubscribe%20me>,
         <https://lists.shop.example/u/abc123?list=fall&amp=1>
        List-Unsubscribe-Post: List-Unsubscribe=One-Click
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <html><body><p>New arrivals. <a href=3D"https://shop.example/new?utm_source=3D=
        mail&amp;utm_medium=3Demail">Shop   the  sale</a></p>
        <a href=3D"https://www.google.com/url?q=3Dhttps%3A%2F%2Fblog.example%2Fpost%3Fid%3D7&amp;sa=3DD">Read the blog</a>
        <a href=3D"https://shop.example/new?utm_source=3Dmail&amp;utm_medium=3Demail"><img src=3D"https://cdn.shop.example/banner.png" alt=3D""></a>
        <a href=3D"https://click.shop.example/track?url=3Dhttps%3A%2F%2Fshop.example%2Fhats">Hats</a>
        <a href=3D"mailto:help@shop.example">Email us</a>
        <p style=3D"color:#999999">Don't want these? <a href=3D"https://lists.shop.example/prefs?u=3Dabc123">Unsubscribe</a></p>
        </body></html>
        """

    // MARK: - Links

    func testHTMLOnlyLinksKeepAnchorTextAndAreDeduplicated() throws {
        let links = MailExtraction(try message(htmlOnly), parts: [.links]).links
        XCTAssertEqual(links, [
            MailExtraction.Link(url: "https://shop.example/new?utm_source=mail&utm_medium=email",
                                text: "Shop the sale", isUnsubscribe: false),
            MailExtraction.Link(url: "https://blog.example/post?id=7", text: "Read the blog", isUnsubscribe: false),
            MailExtraction.Link(url: "https://click.shop.example/track?url=https%3A%2F%2Fshop.example%2Fhats",
                                text: "Hats", isUnsubscribe: false),
            MailExtraction.Link(url: "https://lists.shop.example/prefs?u=abc123", text: "Unsubscribe", isUnsubscribe: true),
        ])
    }

    func testPlainTextLinksTrimProsePunctuation() {
        let links = MailLinks.find(html: nil, text: """
            Read it at https://docs.example/guide. Or see (https://docs.example/a_(b)) and
            <https://docs.example/c?x=1&y=2>, then HTTPS://Docs.Example/Upper!
            To stop these, go to https://news.example/unsub?id=9.
            Not links: ftp://files.example/x, mailto:a@b.example, http://, javascript:alert(1)
            """)
        XCTAssertEqual(links.map(\.url), [
            "https://docs.example/guide", "https://docs.example/a_(b)", "https://docs.example/c?x=1&y=2",
            "HTTPS://Docs.Example/Upper", "https://news.example/unsub?id=9",
        ])
        XCTAssertEqual(links.map(\.isUnsubscribe), [false, false, false, false, true])
        XCTAssertTrue(links.allSatisfy { $0.text == nil })
    }

    func testAPlainPartAndItsHTMLAlternativeGiveOneLinkWithText() throws {
        let links = MailExtraction(try message("""
            From: a@example.com
            Subject: Hello
            Content-Type: multipart/alternative; boundary="b"

            --b
            Content-Type: text/plain

            Docs: https://docs.example/start
            --b
            Content-Type: text/html

            <a href="https://docs.example/start">Get started</a>
            --b--
            """), parts: [.links]).links
        XCTAssertEqual(links, [MailExtraction.Link(url: "https://docs.example/start", text: "Get started", isUnsubscribe: false)])
    }

    func testRedirectorsUnwrapOnlyAPlainTargetInAQueryParameter() {
        XCTAssertEqual(MailLinks.unwrapped("https://www.google.com/url?q=https://a.example/x%3Fy%3D1&sa=D"),
                       "https://a.example/x?y=1")
        XCTAssertEqual(MailLinks.unwrapped("https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.google.com%2Furl%3Fq%3Dhttps%253A%252F%252Fb.example%252F&data=x"),
                       "https://b.example/", "nested wrappers unwrap in turn")
        XCTAssertEqual(MailLinks.unwrapped("https://l.facebook.com/l.php?u=https%3A%2F%2Fc.example%2F&h=AT0"),
                       "https://c.example/")
        XCTAssertEqual(MailLinks.unwrapped("https://www.linkedin.com/redir/redirect?url=https%3A%2F%2Fd.example&urlhash=x"),
                       "https://d.example")
        // Left alone: no target, a target that is not a URL, an unknown tracker.
        for url in ["https://www.google.com/url?sa=D",
                    "https://www.google.com/url?q=not-a-url",
                    "https://www.google.com/url?q=javascript:alert(1)",
                    "https://www.google.com/search?q=https://e.example",
                    "https://esp.example/click?url=https%3A%2F%2Ff.example"] {
            XCTAssertEqual(MailLinks.unwrapped(url), url)
        }
    }

    func testUnsubscribeWordsMarkLinks() {
        XCTAssertTrue(MailLinks.saysUnsubscribe("Se désabonner"))
        XCTAssertTrue(MailLinks.saysUnsubscribe("https://x.example/OptOut?id=1"))
        XCTAssertFalse(MailLinks.saysUnsubscribe("Subscribe to our newsletter"))
    }

    // MARK: - List-Unsubscribe

    func testListUnsubscribeTargetsAndOneClick() throws {
        let unsubscribe = MailExtraction(try message(htmlOnly), parts: [.unsubscribe]).unsubscribe
        XCTAssertEqual(unsubscribe, MailExtraction.Unsubscribe(
            mailto: ["mailto:leave@lists.shop.example?subject=unsubscribe%20me"],
            https: ["https://lists.shop.example/u/abc123?list=fall&amp=1"], oneClick: true))
    }

    func testNoListUnsubscribeHeader() throws {
        let unsubscribe = MailExtraction(try message("From: a@example.com\nSubject: Hi\n\nHello\n"),
                                         parts: [.unsubscribe]).unsubscribe
        XCTAssertEqual(unsubscribe, MailExtraction.Unsubscribe(mailto: [], https: [], oneClick: false))
    }

    func testMalformedListUnsubscribeHeaders() {
        // No angle brackets at all, as a few senders write it.
        XCTAssertEqual(MailLinks.unsubscribe(header: "https://u.example/x, mailto:u@example.com", post: nil),
                       MailExtraction.Unsubscribe(mailto: ["mailto:u@example.com"], https: ["https://u.example/x"], oneClick: false))
        // http:, a bare host, garbage and duplicates are dropped.
        XCTAssertEqual(MailLinks.unsubscribe(header: "<http://u.example/x>, <https://>, <junk>, <https://u.example/y>, <https://u.example/y>",
                                             post: "List-Unsubscribe=One-Click"),
                       MailExtraction.Unsubscribe(mailto: [], https: ["https://u.example/y"], oneClick: true))
        XCTAssertEqual(MailLinks.unsubscribe(header: "<https://u.example/y>", post: " list-unsubscribe = one-click ").oneClick, true)
        XCTAssertEqual(MailLinks.unsubscribe(header: "<https://u.example/y>", post: "One-Click").oneClick, false)
        XCTAssertEqual(MailLinks.unsubscribe(header: "", post: nil),
                       MailExtraction.Unsubscribe(mailto: [], https: [], oneClick: false))
    }

    func testEncodedWordAndFoldedHeaders() throws {
        let unsubscribe = MailExtraction(try message("""
            From: a@example.com
            Subject: =?UTF-8?B?SGVsbG8=?=
            List-Unsubscribe:
              <https://u.example/a
             bc>
            List-Unsubscribe-Post:
             List-Unsubscribe=One-Click

            Hi
            """), parts: [.unsubscribe]).unsubscribe
        XCTAssertEqual(unsubscribe?.https, ["https://u.example/abc"])
        XCTAssertEqual(unsubscribe?.oneClick, true)
    }

    // MARK: - mailto

    func testMailtoWithSubjectAndBody() {
        let email = MailtoMessage("mailto:leave%2Blist@lists.example?Subject=Unsubscribe%20me&body=list%3Dfall%0Aid%3D42&cc=audit@lists.example")
        XCTAssertEqual(email, MailtoMessage(to: "leave+list@lists.example", cc: "audit@lists.example",
                                            subject: "Unsubscribe me", body: "list=fall\nid=42"))
    }

    /// `--yes --send` copies every cc, so the dry run must show them.
    func testAMailtoDryRunShowsEveryRecipient() throws {
        let target = "mailto:leave@lists.example?cc=audit@lists.example,owner@lists.example"
        let plan = UnsubscribePlan(method: .mailto, target: target, email: MailtoMessage(target))
        let result = UnsubscribeResult(id: "m@x", plan: plan, send: true, status: .dryRun)
        XCTAssertTrue(result.humanLine.contains("to leave@lists.example"), result.humanLine)
        XCTAssertTrue(result.humanLine.contains("cc: audit@lists.example,owner@lists.example"), result.humanLine)
        let json = try JSONSerialization.jsonObject(with: Output.encoder.encode(result)) as? [String: Any]
        let email = try XCTUnwrap(json?["email"] as? [String: Any])
        XCTAssertEqual(email["to"] as? String, "leave@lists.example")
        XCTAssertEqual(email["cc"] as? String, "audit@lists.example,owner@lists.example")
    }

    func testMailtoWithoutSubjectOrBodyGetsOne() {
        XCTAssertEqual(MailtoMessage("MAILTO:leave@lists.example"),
                       MailtoMessage(to: "leave@lists.example", cc: nil, subject: "unsubscribe", body: ""))
    }

    func testMailtoAddressCanComeFromTheToParameter() {
        XCTAssertEqual(MailtoMessage("mailto:?to=leave@lists.example&subject=stop")?.to, "leave@lists.example")
    }

    func testMailtoWithoutAnAddressIsRejected() {
        XCTAssertNil(MailtoMessage("mailto:?subject=stop"))
        XCTAssertNil(MailtoMessage("mailto:not-an-address"))
        XCTAssertNil(MailtoMessage("https://u.example/x"))
    }

    // MARK: - The decision

    func plan(mailto: [String] = [], https: [String] = [], oneClick: Bool = false,
              links: [MailExtraction.Link] = []) -> UnsubscribePlan? {
        UnsubscribePlan(MailExtraction(links: links, unsubscribe: .init(mailto: mailto, https: https, oneClick: oneClick)))
    }

    func testOneClickWinsWhenOffered() {
        XCTAssertEqual(plan(mailto: ["mailto:u@example.com"], https: ["https://u.example/1"], oneClick: true),
                       UnsubscribePlan(method: .oneClick, target: "https://u.example/1", email: nil))
    }

    func testMailtoBeatsAnHTTPSLinkWithoutOneClick() {
        XCTAssertEqual(plan(mailto: ["mailto:u@example.com?subject=stop"], https: ["https://u.example/1"])?.method, .mailto)
        XCTAssertEqual(plan(mailto: ["mailto:u@example.com?subject=stop"], https: ["https://u.example/1"])?.email?.subject, "stop")
    }

    func testOneClickWithoutAnHTTPSTargetFallsToMailto() {
        XCTAssertEqual(plan(mailto: ["mailto:u@example.com"], oneClick: true)?.method, .mailto)
    }

    func testAnHTTPSLinkWithoutOneClickIsOnlyOpened() {
        XCTAssertEqual(plan(https: ["https://u.example/1"]),
                       UnsubscribePlan(method: .open, target: "https://u.example/1", email: nil))
    }

    func testABodyLinkIsOnlyOpened() {
        let links = [MailExtraction.Link(url: "https://x.example/a", text: "Shop", isUnsubscribe: false),
                     MailExtraction.Link(url: "https://x.example/unsub", text: "Unsubscribe", isUnsubscribe: true)]
        XCTAssertEqual(plan(mailto: ["mailto:nobody"], links: links),
                       UnsubscribePlan(method: .open, target: "https://x.example/unsub", email: nil))
    }

    func testNoWayOut() {
        XCTAssertNil(plan(links: [MailExtraction.Link(url: "https://x.example/a", text: nil, isUnsubscribe: false)]))
    }

    // MARK: - Output

    func testJSONShape() throws {
        let extraction = MailExtraction(try message(htmlOnly))
        let json = String(data: try Output.encoder.encode(extraction), encoding: .utf8)!
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["codes", "links", "unsubscribe"])
        XCTAssertTrue(json.hasPrefix(#"{"codes":[],"links":[{"isUnsubscribe":false,"text":"Shop the sale","url":"#), json)
        XCTAssertTrue(json.hasSuffix(#""unsubscribe":{"https":["https:\/\/lists.shop.example\/u\/abc123?list=fall&amp=1"],"mailto":["mailto:leave@lists.shop.example?subject=unsubscribe%20me"],"oneClick":true}}"#), json)
        let codesOnly = MailExtraction(try message(htmlOnly), parts: [.codes])
        XCTAssertEqual(String(data: try Output.encoder.encode(codesOnly), encoding: .utf8), #"{"codes":[]}"#)
    }

    func testHumanOutput() throws {
        let text = MailExtraction(try message(htmlOnly), parts: [.codes, .unsubscribe]).humanLine
        XCTAssertEqual(text, """
            codes: none
            unsubscribe:
              https: https://lists.shop.example/u/abc123?list=fall&amp=1
              mailto: mailto:leave@lists.shop.example?subject=unsubscribe%20me
              one-click: yes
            """)
    }
}
