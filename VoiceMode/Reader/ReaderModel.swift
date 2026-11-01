import Foundation
import Observation

/// Owns pagination for the open book and keeps the page and the narration on the same position.
@Observable
final class ReaderModel {
    let book: Book
    let document: Document
    let player: NarrationPlayer
    private let session: PlaybackSession
    /// UTF-16 offset where each chapter starts in the whole book, plus the total length at the end.
    let chapterStarts: [Int]

    private(set) var chapterIndex: Int
    private(set) var pages: [NSRange] = []
    private(set) var pageIndex = 0

    @ObservationIgnored private var pageSize: CGSize = .zero
    @ObservationIgnored private var style = ReaderStyle(fontSize: 19)
    @ObservationIgnored private var restoreOffset: Int
    @ObservationIgnored private var sentenceCache: [Int: [NSRange]] = [:]

    init(book: Book, session: PlaybackSession) {
        let document = (try? book.loadDocument())
            ?? Document(title: book.title, chapters: [Chapter(title: book.title, text: "This book couldn’t be loaded.")])
        self.book = book
        self.document = document
        self.session = session
        player = session.player(for: book, document: document)
        // Reopening the book that's narrating: start on the sentence being spoken.
        let start = player.isEngaged ? player.position ?? book.position : book.position
        chapterIndex = min(max(start.chapter, 0), document.chapters.count - 1)
        restoreOffset = start.offset
        chapterStarts = document.chapters.reduce(into: [0]) { $0.append($0.last! + ($1.text as NSString).length) }
    }

    /// Call when the reader appears. Not done in `init`: SwiftUI may construct the model repeatedly,
    /// and writing to the book there re-renders the library, which constructs it again.
    func didOpen() {
        book.lastOpenedAt = .now
    }

    var chapter: Chapter { document.chapters[chapterIndex] }
    var currentPage: NSRange? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }
    var position: ReadingPosition { ReadingPosition(chapter: chapterIndex, offset: currentPage?.location ?? restoreOffset) }

    var pageText: String {
        guard let currentPage else { return "" }
        return (chapter.text as NSString).substring(with: currentPage)
    }

    /// The sentence being narrated, relative to the current page.
    var pageHighlight: NSRange? {
        guard player.status != .idle, let spoken = player.position, spoken.chapter == chapterIndex,
              let page = currentPage else { return nil }
        let sentences = sentences(inChapter: chapterIndex)
        guard let index = TextSegmenter.index(of: spoken.offset, in: sentences) else { return nil }
        let clipped = NSIntersectionRange(sentences[index], page)
        guard clipped.length > 0 else { return nil }
        return NSRange(location: clipped.location - page.location, length: clipped.length)
    }

    // MARK: Layout

    func layout(pageSize: CGSize, style: ReaderStyle) {
        guard pageSize.width > 50, pageSize.height > 50, pageSize != self.pageSize || style != self.style else { return }
        let anchor = position.offset
        self.pageSize = pageSize
        self.style = style
        paginate(chapter: chapterIndex, showing: anchor)
    }

    private func paginate(chapter: Int, showing offset: Int) {
        chapterIndex = chapter
        pages = Paginator.pages(for: document.chapters[chapter].text, size: pageSize, style: style)
        pageIndex = TextSegmenter.index(of: offset, in: pages) ?? 0
        savePosition()
    }

    private var isLaidOut: Bool { pageSize != .zero }

    // MARK: Navigation (user initiated)

    func nextPage() {
        if pageIndex + 1 < pages.count {
            pageIndex += 1
        } else if chapterIndex + 1 < document.chapters.count {
            paginate(chapter: chapterIndex + 1, showing: 0)
        } else {
            return
        }
        userDidNavigate()
    }

    func previousPage() {
        if pageIndex > 0 {
            pageIndex -= 1
        } else if chapterIndex > 0 {
            paginate(chapter: chapterIndex - 1, showing: .max)
        } else {
            return
        }
        userDidNavigate()
    }

    func goTo(_ target: ReadingPosition) {
        guard document.chapters.indices.contains(target.chapter) else { return }
        paginate(chapter: target.chapter, showing: target.offset)
        userDidNavigate()
    }

    // MARK: Whole-book navigation

    private var bookLength: Int { chapterStarts.last ?? 0 }

    /// How far through the whole book the current page is, 0...1.
    var progress: Double {
        guard bookLength > 0 else { return 0 }
        return Double(chapterStarts[chapterIndex] + position.offset) / Double(bookLength)
    }

    /// Where each chapter after the first begins, as a fraction of the book.
    var chapterMarks: [Double] {
        guard bookLength > 0 else { return [] }
        return chapterStarts.dropFirst().dropLast().map { Double($0) / Double(bookLength) }
    }

    func position(atFraction fraction: Double) -> ReadingPosition {
        let target = Int((min(max(fraction, 0), 1) * Double(bookLength)).rounded())
        let chapter = min(TextSegmenter.index(of: target, in: chapterStarts.map { NSRange(location: $0, length: 0) }) ?? 0,
                          document.chapters.count - 1)
        return ReadingPosition(chapter: chapter, offset: target - chapterStarts[chapter])
    }

    /// Section title and opening words at a point in the book, shown while scrubbing.
    func preview(atFraction fraction: Double) -> (title: String, snippet: String) {
        let target = position(atFraction: fraction)
        let text = document.chapters[target.chapter].text as NSString
        var start = min(target.offset, text.length)
        let whitespace = CharacterSet.whitespacesAndNewlines
        // Back up to the start of the word so the snippet doesn't begin mid-word.
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)), !whitespace.contains(scalar) { start -= 1 }
        let snippet = text.substring(with: NSRange(location: start, length: min(140, text.length - start)))
            .replacingOccurrences(of: "\n", with: " ")
        return (sectionTitle(at: target), snippet)
    }

    // MARK: Contents

    /// The innermost heading at or before `target`, or the chapter title.
    func sectionTitle(at target: ReadingPosition) -> String {
        let chapter = document.chapters[target.chapter]
        guard let heading = chapter.headings.last(where: { $0.offset <= target.offset }) else { return chapter.title }
        return "\(chapter.title) · \(heading.title)"
    }

    /// The contents entry the current page belongs to: the chapter, and the last heading that starts on or before this page.
    var currentContentsEntry: (chapter: Int, heading: Int?) {
        let pageEnd = currentPage.map { NSMaxRange($0) - 1 } ?? position.offset
        return (chapterIndex, chapter.headings.lastIndex { $0.offset <= pageEnd })
    }

    /// Reading and listening share one position: turning the page while narrating jumps the audio there.
    private func userDidNavigate() {
        savePosition()
        if player.isActive { player.play(from: position) }
    }

    // MARK: Narration

    func togglePlayback() {
        session.activate(player, book: book, document: document)
        switch player.status {
        case .playing, .loading:
            player.pause()
        case .paused where pageContains(player.position):
            player.resume()
        default:
            player.play(from: position)
        }
    }

    /// Keeps the visible page on whatever is being spoken.
    func follow(_ spoken: ReadingPosition?) {
        guard let spoken, isLaidOut, player.isEngaged else { return }
        if spoken.chapter != chapterIndex {
            paginate(chapter: spoken.chapter, showing: spoken.offset)
        } else if let index = TextSegmenter.index(of: spoken.offset, in: pages), index != pageIndex {
            pageIndex = index
            savePosition()
        }
    }

    private func pageContains(_ spoken: ReadingPosition?) -> Bool {
        guard let spoken, spoken.chapter == chapterIndex, let page = currentPage else { return false }
        return spoken.offset >= page.location && spoken.offset <= NSMaxRange(page)
    }

    private func sentences(inChapter index: Int) -> [NSRange] {
        if let cached = sentenceCache[index] { return cached }
        let ranges = TextSegmenter.sentences(in: document.chapters[index].text)
        sentenceCache[index] = ranges
        return ranges
    }

    /// Reading progress as shown to the user: like `progress`, but the last page counts as finished.
    var readingProgress: Double {
        let onLastPage = chapterIndex == document.chapters.count - 1 && pageIndex == pages.count - 1
        return onLastPage ? 1 : progress
    }

    private func savePosition() {
        book.position = position
        book.readingProgress = readingProgress
    }
}
