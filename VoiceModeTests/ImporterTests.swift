import Foundation
import Testing
@testable import VoiceMode

struct HTMLTextTests {
    @Test func stripsTagsScriptsAndEntities() {
        let html = """
        <html><head><title>Ignored</title></head><body>
        <script>var x = 1;</script>
        <h1>Title &amp; Co</h1>
        <p>Hello,
           <em>world</em>&nbsp;&#8212; &#x2019;ok</p>
        <p></p><div>Second</div>
        </body></html>
        """
        #expect(HTMLText.plainText(fromHTML: html) == "Title & Co\nHello, world — ’ok\nSecond")
    }

    @Test func dropsPageChromeForWebPages() {
        let html = "<nav><a>Home</a></nav><article><p>Body</p></article><footer>©</footer>"
        #expect(HTMLText.plainText(fromHTML: html, dropPageChrome: true) == "Body")
    }

    @Test func extractsTitleAndHeading() {
        let html = "<title> My  Page </title><h2 class='x'>Chapter <b>One</b></h2>"
        #expect(HTMLText.title(fromHTML: html) == "My Page")
        #expect(HTMLText.firstHeading(inHTML: html) == "Chapter One")
    }
}

struct TextImporterTests {
    @Test func splitsChaptersOnHeadings() {
        let raw = "Preface text\nwrapped.\n\nCHAPTER I.\n\nFirst para\nwrapped.\n\nSecond para.\n\nCHAPTER II.\n\nMore."
        let document = TextImporter.document(fromPlainText: raw, title: "Book")
        #expect(document.chapters.map(\.title) == ["Book", "CHAPTER I.", "CHAPTER II."])
        #expect(document.chapters[1].text == "First para wrapped.\nSecond para.")
    }

    @Test func pdfReflowJoinsLinesAndDehyphenates() {
        let text = "This is a sen-\ntence that wraps\nacross lines.\nNext paragraph"
        #expect(PDFImporter.reflow(text) == "This is a sentence that wraps across lines.\nNext paragraph")
    }
}

struct HeadingTests {
    @Test func recordsHeadingOffsetsInPlainText() {
        let html = "<h1>Chapter One</h1><p>Intro text.</p><h2 id='a'>The <em>Ball</em></h2><p>Dancing.</p><h3>Aftermath</h3><p>Home.</p>"
        let (text, headings) = HTMLText.textAndHeadings(fromHTML: html)
        #expect(text == "Chapter One\nIntro text.\nThe Ball\nDancing.\nAftermath\nHome.")
        #expect(headings.map(\.title) == ["Chapter One", "The Ball", "Aftermath"])
        #expect(headings.map(\.level) == [1, 2, 3])
        let ns = text as NSString
        for heading in headings {
            #expect(ns.substring(with: NSRange(location: heading.offset, length: (heading.title as NSString).length)) == heading.title)
        }
        #expect(headings.droppingTitle("Chapter One").map(\.title) == ["The Ball", "Aftermath"])
    }

    @Test func pdfPageOffsetsPointAtEachPagesText() {
        let pages = ["First page ends mid", "sentence here. Second para.", "Third page."]
        let (text, offsets) = PDFImporter.reflow(pages: pages)
        let ns = text as NSString
        #expect(text == "First page ends mid sentence here. Second para.\nThird page.")
        #expect(offsets[0] == 0)
        #expect(ns.substring(from: offsets[1]).hasPrefix("sentence here."))
        #expect(ns.substring(from: offsets[2]).hasPrefix("Third page."))
    }

    @Test func decodesChaptersSavedBeforeHeadingsExisted() throws {
        let json = #"{"title":"T","chapters":[{"title":"C","text":"x"}]}"#
        let document = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        #expect(document.chapters[0].headings.isEmpty)
    }
}

struct HTMLAttributeTests {
    @Test func ignoresAngleBracketsInsideQuotedAttributes() {
        let html = #"<p>Before</p><span data-mw='{"a":"[[X]]<br/>[[Y]]"}' class="x">Visible</span><p title="a > b">After</p>"#
        #expect(HTMLText.plainText(fromHTML: html) == "Before\nVisible\nAfter")
    }
}
