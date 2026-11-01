import Foundation
import PDFKit

nonisolated enum PDFImporter {
    private static let pagesPerSection = 10

    static func document(fromPDFAt url: URL) throws -> Document {
        guard let pdf = PDFDocument(url: url) else { throw ImportError.unreadable }
        let pageTexts = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }

        // Prefer the PDF's own outline: top-level items become chapters, nested items headings.
        var sections: [(title: String, pages: Range<Int>, outline: PDFOutline?)] = []
        if let outline = pdf.outlineRoot, outline.numberOfChildren > 1 {
            let starts = (0..<outline.numberOfChildren).compactMap { i -> (PDFOutline, Int)? in
                guard let item = outline.child(at: i), let page = item.destination?.page else { return nil }
                return (item, pdf.index(for: page))
            }.sorted { $0.1 < $1.1 }
            for (i, start) in starts.enumerated() {
                let end = i + 1 < starts.count ? starts[i + 1].1 : pdf.pageCount
                if end > start.1 { sections.append((start.0.label ?? "Section \(i + 1)", start.1..<end, start.0)) }
            }
        }
        if sections.isEmpty {
            sections = stride(from: 0, to: pdf.pageCount, by: pagesPerSection).map { start in
                let end = min(start + pagesPerSection, pdf.pageCount)
                return ("Pages \(start + 1)–\(end)", start..<end, nil)
            }
        }

        let chapters = sections.map { section in
            let (text, pageOffsets) = reflow(pages: Array(pageTexts[section.pages]))
            var headings: [Heading] = []
            if let outline = section.outline {
                collectHeadings(in: outline, level: 2, into: &headings) { page in
                    let index = pdf.index(for: page)
                    return section.pages.contains(index) ? pageOffsets[index - section.pages.lowerBound] : nil
                }
            }
            return Chapter(title: section.title, text: text, headings: headings.sorted { $0.offset < $1.offset })
        }

        let attributes = pdf.documentAttributes ?? [:]
        return Document(
            title: (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nonEmpty ?? url.deletingPathExtension().lastPathComponent,
            author: (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.nonEmpty,
            chapters: chapters,
            cover: pdf.page(at: 0)?.thumbnail(of: CGSize(width: 400, height: 600), for: .mediaBox).cgImage.flatMap(CoverImage.jpeg)
        )
    }

    private static func collectHeadings(in item: PDFOutline, level: Int, into headings: inout [Heading],
                                        offsetOf: (PDFPage) -> Int?) {
        for i in 0..<item.numberOfChildren {
            guard let child = item.child(at: i) else { continue }
            if let label = child.label?.nonEmpty, let page = child.destination?.page, let offset = offsetOf(page) {
                headings.append(Heading(title: label, level: level, offset: offset))
            }
            collectHeadings(in: child, level: level + 1, into: &headings, offsetOf: offsetOf)
        }
    }

    /// PDF text comes as visual lines. Rejoin them into paragraphs, treating a line that
    /// ends a sentence as a paragraph break and undoing end-of-line hyphenation.
    static func reflow(_ text: String) -> String {
        reflow(pages: [text]).text
    }

    /// Reflows consecutive pages into one text and reports where each page's text begins in it.
    static func reflow(pages: [String]) -> (text: String, pageOffsets: [Int]) {
        var paragraphs: [String] = []
        var length = 0 // UTF-16 length of paragraphs joined so far
        var current = ""
        var pageOffsets: [Int] = []
        func flush() {
            guard !current.isEmpty else { return }
            length += (paragraphs.isEmpty ? 0 : 1) + current.utf16.count
            paragraphs.append(current)
            current = ""
        }
        for page in pages {
            let paragraphStart = paragraphs.isEmpty ? length : length + 1
            pageOffsets.append(current.isEmpty ? paragraphStart : paragraphStart + current.utf16.count + 1)
            for rawLine in page.components(separatedBy: .newlines) {
                let line = rawLine.replacingRegex(#"[\s\u00A0]+"#, with: " ").trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush(); continue }
                if current.hasSuffix("-") {
                    current.removeLast()
                    current += line
                } else {
                    current += current.isEmpty ? line : " " + line
                }
                if let last = line.last, ".!?:\"”".contains(last) { flush() }
            }
        }
        flush()
        let text = paragraphs.joined(separator: "\n")
        let end = text.utf16.count
        return (text, pageOffsets.map { min($0, end) })
    }
}
