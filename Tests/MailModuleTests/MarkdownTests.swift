import XCTest
@testable import MailModule

final class MarkdownTests: XCTestCase {
    func testHeadingsAndParagraphs() {
        XCTAssertEqual(Markdown.html("# Title\n\nFirst line\nsecond line\n\n### Small ###"),
                       "<h1>Title</h1>\n<p>First line<br>\nsecond line</p>\n<h3>Small</h3>")
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(Markdown.html("#hashtag"), "<p>#hashtag</p>")
        XCTAssertEqual(Markdown.html("####### seven"), "<p>####### seven</p>")
    }

    func testUnorderedAndOrderedLists() {
        XCTAssertEqual(Markdown.html("- one\n* two\n  wrapped\n\n1. first\n2) second"),
                       "<ul>\n<li>one</li>\n<li>two wrapped</li>\n</ul>\n<ol>\n<li>first</li>\n<li>second</li>\n</ol>")
    }

    func testQuoteRuleAndFencedCode() {
        XCTAssertEqual(Markdown.html("> quoted **bold**\n> more\n\n---\n\n```\nlet a = \"<b>\" && b\n```"),
                       "<blockquote>\n<p>quoted <strong>bold</strong><br>\nmore</p>\n</blockquote>\n<hr>\n<pre><code>let a = &quot;&lt;b&gt;&quot; &amp;&amp; b</code></pre>")
    }

    func testInlineFormatting() {
        XCTAssertEqual(Markdown.inline("**strong** __also__ *em* _em_ `a<b`"),
                       "<strong>strong</strong> <strong>also</strong> <em>em</em> <em>em</em> <code>a&lt;b</code>")
    }

    func testUnderscoresInsideWordsStayLiteral() {
        XCTAssertEqual(Markdown.inline("snake_case_name and 2 * 3 * 4"), "snake_case_name and 2 * 3 * 4")
    }

    func testBackslashEscapesMarkup() {
        XCTAssertEqual(Markdown.inline(#"\*not em\* and C:\path"#), #"*not em* and C:\path"#)
    }

    func testLinksAndAutolinks() {
        XCTAssertEqual(Markdown.inline("[site](https://example.com/a?b=1&c=2) <mailto:x@y.z>"),
                       #"<a href="https://example.com/a?b=1&amp;c=2">site</a> <a href="mailto:x@y.z">mailto:x@y.z</a>"#)
    }

    func testLinksWithOtherSchemesStayText() {
        XCTAssertEqual(Markdown.inline("[x](javascript:alert(1)) <file:///etc/passwd>"),
                       "[x](javascript:alert(1)) &lt;file:///etc/passwd&gt;")
    }

    func testHostileInputIsEscapedNotInterpreted() {
        let hostile = #"<script>alert("x")</script> 'q' \ » ✓ é 日本"#
        XCTAssertEqual(Markdown.html(hostile),
                       #"<p>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &#39;q&#39; \ » ✓ é 日本</p>"#)
    }

    func testQuoteInLinkTargetCannotBreakTheAttribute() {
        XCTAssertEqual(Markdown.inline(#"[a](https://e.com/"onmouseover=x)"#),
                       #"<a href="https://e.com/&quot;onmouseover=x">a</a>"#)
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(Markdown.html("# A\r\n\r\nb"), "<h1>A</h1>\n<p>b</p>")
    }

    func testEmptySource() {
        XCTAssertEqual(Markdown.html(""), "")
        XCTAssertEqual(Markdown.html("\n\n  \n"), "")
    }
}
