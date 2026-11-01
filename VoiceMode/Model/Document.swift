import Foundation

/// Normalized content produced by every importer. Chapter text is plain text with
/// one paragraph per line; all offsets into it are UTF-16 (NSString) offsets.
nonisolated struct Document: Codable, Sendable {
    var title: String
    var author: String?
    var chapters: [Chapter]
    /// JPEG cover from the importer. Moved onto `Book.coverData` rather than stored with the text.
    var cover: Data?
}

nonisolated struct Chapter: Codable, Sendable, Hashable {
    var title: String
    var text: String
    /// Sub-headings inside the chapter, in reading order.
    var headings: [Heading] = []

    init(title: String, text: String, headings: [Heading] = []) {
        self.title = title
        self.text = text
        self.headings = headings
    }

    init(from decoder: Decoder) throws {
        // Books imported before headings existed have no "headings" key.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        text = try container.decode(String.self, forKey: .text)
        headings = try container.decodeIfPresent([Heading].self, forKey: .headings) ?? []
    }
}

/// A heading within a chapter. `level` follows HTML (1 = h1); `offset` is UTF-16 into the chapter text.
nonisolated struct Heading: Codable, Sendable, Hashable {
    var title: String
    var level: Int
    var offset: Int
}

/// The single source of truth for "where am I" in a book, shared by reading and listening.
nonisolated struct ReadingPosition: Codable, Sendable, Hashable {
    var chapter: Int
    var offset: Int
}

nonisolated extension Document {
    /// UTF-16 offset where each chapter starts in the whole book, plus the total length at the end.
    var chapterStarts: [Int] {
        chapters.reduce(into: [0]) { $0.append($0.last! + ($1.text as NSString).length) }
    }

    /// How far through the whole book `position` is, 0...1.
    func fraction(at position: ReadingPosition) -> Double {
        let starts = chapterStarts
        guard let total = starts.last, total > 0, starts.indices.contains(position.chapter) else { return 0 }
        return min(Double(starts[position.chapter] + position.offset) / Double(total), 1)
    }
}
