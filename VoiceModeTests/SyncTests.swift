import Foundation
import Testing
@testable import VoiceMode

struct SyncTests {
    private let text = SampleContent.document.chapters[0].text

    @Test func chunksCoverTextContiguously() {
        let chunks = TextSegmenter.chunks(in: text, preferred: 300, maximum: 800)
        #expect(chunks.count > 1)
        #expect(chunks.first?.location == 0)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(NSMaxRange(a) == b.location) }
        #expect(NSMaxRange(chunks.last!) == (text as NSString).length)
    }

    @Test func sentencesExcludeTrailingNewlines() {
        let ns = "One. Two!\nThree" as NSString
        #expect(TextSegmenter.sentences(in: ns as String).map { ns.substring(with: $0) } == ["One.", "Two!", "Three"])
    }

    @Test func indexFindsContainingRange() {
        let ranges = [NSRange(location: 0, length: 10), NSRange(location: 10, length: 5), NSRange(location: 15, length: 5)]
        #expect(TextSegmenter.index(of: 0, in: ranges) == 0)
        #expect(TextSegmenter.index(of: 12, in: ranges) == 1)
        #expect(TextSegmenter.index(of: 99, in: ranges) == 2)
        #expect(TextSegmenter.index(of: -1, in: ranges) == nil)
    }

    @Test func alignmentMapsUTF16OffsetsBothWays() {
        // "a😀b": the emoji is two UTF-16 units, so "b" sits at offset 3.
        let alignment = ElevenLabsProvider.Alignment(characters: ["a", "😀", "b"], characterStartTimesSeconds: [0, 0.5, 1.0])
        let marks = ElevenLabsProvider.marks(from: alignment)
        #expect(marks == [CharMark(offset: 0, start: 0), CharMark(offset: 1, start: 0.5), CharMark(offset: 3, start: 1.0)])

        let clip = SpeechClip(audioURL: URL(filePath: "/dev/null"), marks: marks)
        #expect(clip.time(forOffset: 2) == 1.0)
        #expect(clip.time(forOffset: 3) == 1.0)
        #expect(clip.offset(atTime: 0.7) == 1)
        #expect(clip.offset(atTime: 5) == 3)
    }

    @Test func paginationCoversChapterWithoutGaps() {
        let pages = Paginator.pages(for: text, size: CGSize(width: 320, height: 500), style: ReaderStyle(fontSize: 19))
        #expect(pages.count > 1)
        #expect(pages.first?.location == 0)
        for (a, b) in zip(pages, pages.dropFirst()) { #expect(NSMaxRange(a) == b.location) }
        #expect(NSMaxRange(pages.last!) == (text as NSString).length)
    }
}

struct AudioTagTests {
    @Test func mapsTaggedOffsetsBackToOriginal() throws {
        let original = "“Oh!” cried she.\nHe sat."
        let tagged = "[excited] “Oh!” cried she.\n[sighs] He sat."
        let map = try #require(AudioTags.offsetMap(tagged: tagged, original: original))
        let t = tagged as NSString
        #expect(map.count == t.length + 1)
        // Tag characters point at the text they precede.
        #expect(map[0] == 0)
        #expect(map[t.range(of: "“Oh").location] == 0)
        #expect(map[t.range(of: "[sighs]").location] == (original as NSString).range(of: "He").location)
        #expect(map[t.range(of: "He").location] == (original as NSString).range(of: "He").location)
        #expect(map.last == (original as NSString).length)
    }

    @Test func toleratesWhitespaceAroundTags() {
        #expect(AudioTags.offsetMap(tagged: "Fine. [laughs]", original: "Fine.") != nil)
        #expect(AudioTags.offsetMap(tagged: "A [softly] B", original: "A\nB") != nil)
    }

    @Test func rejectsChangedWords() {
        #expect(AudioTags.offsetMap(tagged: "[excited] “Oh!”", original: "“Oh!” cried she.") == nil)
        #expect(AudioTags.offsetMap(tagged: "Hello world", original: "Hello, world") == nil)
    }

    @Test func keepsLiteralBracketsFromOriginal() {
        #expect(AudioTags.offsetMap(tagged: "See [1] here", original: "See [1] here") != nil)
    }

    @Test func remapsAlignmentMarks() {
        let original = "Hi."
        let tagged = "[warmly] Hi."
        let map = AudioTags.offsetMap(tagged: tagged, original: original)!
        let marks = [CharMark(offset: 0, start: 0), CharMark(offset: 9, start: 0.4), CharMark(offset: 11, start: 0.6)]
        #expect(AudioTags.remap(marks, with: map).map(\.offset) == [0, 0, 2])
    }
}

struct CostTests {
    @Test func convertsCreditsAndFormatsSmallAmounts() {
        #expect(Pricing.ttsUSD(credits: 30_000, ratePer1K: Pricing.defaultUSDPer1KCredits) == 5)
        #expect(Pricing.format(0) == "$0.00")
        #expect(Pricing.format(1.234) == "$1.23")
        #expect(Pricing.format(0.0021) == "$0.0021")
    }

    @Test func bookAccumulatesCosts() {
        let book = Book(document: Document(title: "T", chapters: [Chapter(title: "C", text: "x")]), source: "test")
        book.record(SpeechCost(ttsCredits: 120, llmUSD: 0.0004, llmTokens: 300))
        book.record(SpeechCost(ttsCredits: 80, llmUSD: 0.0002, llmTokens: 200))
        #expect(book.ttsCredits == 200)
        #expect(abs(book.llmCostUSD - 0.0006) < 1e-12)
        #expect(book.llmTokens == 500)
        #expect(book.generatedParagraphs == 2)
    }
}

struct ModelNameTests {
    @Test func defaultsToV4Turbo() {
        #expect(ElevenLabsProvider.defaultModelID == "eleven_v4_turbo")
        #expect(Secrets.elevenLabsModelID.nonEmpty != nil || ElevenLabsProvider.activeModelName == "v4 Turbo")
    }
}
