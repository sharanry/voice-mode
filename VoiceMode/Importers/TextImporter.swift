import Foundation

nonisolated enum TextImporter {
    /// Splits plain text into chapters on heading lines like "CHAPTER IV." or "Part 2".
    static func document(fromPlainText raw: String, title: String) -> Document {
        var chapters: [Chapter] = []
        var heading: String?
        var buffer: [String] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            let fallback = chapters.isEmpty ? title : "Part \(chapters.count + 1)"
            chapters.append(Chapter(title: heading ?? fallback, text: buffer.joined(separator: "\n")))
            buffer = []
        }

        for line in TextNormalizer.unwrap(raw).components(separatedBy: "\n") {
            if isHeading(line) {
                flush()
                heading = line
            } else {
                buffer.append(line)
            }
        }
        flush()
        return Document(title: title, author: nil, chapters: chapters)
    }

    static func isHeading(_ line: String) -> Bool {
        line.count < 60
            && line.range(of: #"^(CHAPTER|Chapter|BOOK|Book|PART|Part)\s+[0-9IVXLCivxlc]+\b"#, options: .regularExpression) != nil
    }
}
