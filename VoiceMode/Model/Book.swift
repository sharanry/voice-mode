import Foundation
import SwiftData

@Model
final class Book {
    var title: String
    var author: String?
    var source: String
    var addedAt: Date
    var lastOpenedAt: Date?
    var chapterCount: Int
    var chapterIndex: Int
    var charOffset: Int
    @Attribute(.externalStorage) var contentData: Data
    @Attribute(.externalStorage) var coverData: Data? = nil
    /// Fraction of the whole book read, 0...1, saved by the reader on every page change.
    var readingProgress: Double = 0

    // Running generation cost. Cached replays are free and not counted.
    var ttsCredits: Int = 0
    var llmCostUSD: Double = 0
    var llmTokens: Int = 0
    var generatedParagraphs: Int = 0

    init(document: Document, source: String) {
        title = document.title
        author = document.author
        self.source = source
        addedAt = .now
        chapterCount = document.chapters.count
        chapterIndex = 0
        charOffset = 0
        coverData = document.cover
        var text = document
        text.cover = nil
        contentData = (try? JSONEncoder().encode(text)) ?? Data()
    }

    func loadDocument() throws -> Document {
        try JSONDecoder().decode(Document.self, from: contentData)
    }

    var position: ReadingPosition {
        get { ReadingPosition(chapter: chapterIndex, offset: charOffset) }
        set {
            chapterIndex = newValue.chapter
            charOffset = newValue.offset
        }
    }

    var isFinished: Bool { readingProgress >= 0.99 }

    func record(_ cost: SpeechCost) {
        ttsCredits += cost.ttsCredits
        llmCostUSD += cost.llmUSD
        llmTokens += cost.llmTokens
        generatedParagraphs += 1
    }

    /// When the book was last touched, for "most recent first" ordering.
    var recency: Date { lastOpenedAt ?? addedAt }
}
