import Foundation
import Observation

/// The open book's people and organisations: extracts them once, finds mentions for underlining,
/// and researches cards and pictures on demand. Everything lives in the book's `entities/` folder.
@Observable
final class EntityStore {
    enum State { case idle, extracting, ready }

    private let book: Book
    private let document: Document
    /// Assigns the book's folder key on first use, which must not happen in `init`: writing to the
    /// book while the reader is being built re-renders the library, which builds the reader again.
    private var folder: EntityFolder { EntityFolder(key: book.entityFolderKey()) }
    private let listChat = OpenRouterChat.fromSecrets()
    private let cardChat = OpenRouterChat.forCards()
    private let imageChat = OpenRouterChat.forImages()

    private(set) var state: State = .idle
    private(set) var entities: [Entity] = []
    private(set) var cards: [String: EntityCard] = [:]
    /// Portrait (people) or emblem (organisations) JPEGs, by entity id.
    private(set) var images: [String: Data] = [:]
    private(set) var researching: Set<String> = []
    private(set) var painting: Set<String> = []
    private(set) var failures: Set<String> = []

    @ObservationIgnored private var index = EntityIndex(entities: [])
    @ObservationIgnored private var mentionCache: [Int: [Mention]] = [:]

    var canResearch: Bool { cardChat != nil }

    init(book: Book, document: Document) {
        self.book = book
        self.document = document
        // Books from before entities existed have no folder yet; they're extracted on open.
        // An empty list is tried again on the next open; that's free when there are still no candidates.
        if !book.entityFolder.isEmpty, let saved = folder.loadIndex(), !saved.isEmpty { apply(saved) }
    }

    /// Extracts the entities the first time a book is opened.
    func prepare() {
        guard state == .idle else { return }
        state = .extracting
        Task {
            let (found, usage) = await EntityExtractor.extract(from: document, using: listChat)
            folder.saveIndex(found)
            book.recordEntityUsage(usage)
            apply(found)
        }
    }

    private func apply(_ found: [Entity]) {
        entities = found
        index = EntityIndex(entities: found)
        mentionCache = [:]
        for entity in found {
            cards[entity.id] = folder.loadCard(entity)
            images[entity.id] = folder.loadImage(entity)
        }
        state = .ready
    }

    // MARK: Mentions

    func mentions(inChapter chapter: Int) -> [Mention] {
        guard state == .ready, document.chapters.indices.contains(chapter) else { return [] }
        if let cached = mentionCache[chapter] { return cached }
        let found = index.mentions(in: document.chapters[chapter].text)
        mentionCache[chapter] = found
        return found
    }

    /// Every mention of `entity` before `limit`, in reading order.
    func positions(of entity: Entity, through limit: ReadingPosition) -> [ReadingPosition] {
        guard let target = entities.firstIndex(of: entity), limit.chapter >= 0 else { return [] }
        return (0...min(limit.chapter, document.chapters.count - 1)).flatMap { chapter in
            mentions(inChapter: chapter)
                .filter { $0.entity == target && (chapter < limit.chapter || $0.range.location < limit.offset) }
                .map { ReadingPosition(chapter: chapter, offset: $0.range.location) }
        }
    }

    /// Entities that have appeared before `limit`, most mentioned first.
    func appearances(through limit: ReadingPosition) -> [(entity: Entity, count: Int)] {
        var counts = [Int](repeating: 0, count: entities.count)
        for chapter in 0...max(0, min(limit.chapter, document.chapters.count - 1)) {
            for mention in mentions(inChapter: chapter) where chapter < limit.chapter || mention.range.location < limit.offset {
                counts[mention.entity] += 1
            }
        }
        return counts.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }.map { (entities[$0], counts[$0]) }
    }

    /// The entity a card's relationship refers to, if the book has one by that name.
    func entity(named name: String) -> Entity? {
        entities.first { $0.terms.contains(name) }
    }

    func snippet(at position: ReadingPosition) -> String {
        EntityExtractor.snippet(around: position.offset, in: document.chapters[position.chapter].text as NSString, radius: 70)
            .trimmingCharacters(in: .whitespaces)
    }

    func chapterTitle(_ chapter: Int) -> String {
        document.chapters.indices.contains(chapter) ? document.chapters[chapter].title : ""
    }

    // MARK: Cards and pictures

    /// Researches (or updates) a card, then paints a picture the first time. Only runs when a card is opened.
    func research(_ entity: Entity, through limit: ReadingPosition) {
        guard let chat = cardChat, !researching.contains(entity.id) else { return }
        researching.insert(entity.id)
        failures.remove(entity.id)
        let previous = cards[entity.id]
        Task {
            do {
                let (card, usage) = try await EntityAgent.research(entity, known: entities, in: document, through: limit,
                                                                   previous: previous, chat: chat)
                cards[entity.id] = card
                folder.saveCard(card, for: entity)
                book.recordEntityUsage(usage)
                if images[entity.id] == nil { paint(entity) }
            } catch {
                failures.insert(entity.id)
            }
            researching.remove(entity.id)
        }
    }

    var canPaint: Bool { imageChat != nil }

    /// Draws (or redraws) an entity's picture from its card, in `style` plus any extra details the reader typed.
    func paint(_ entity: Entity, style: ImageStyle? = nil, details: String = "") {
        guard let imageChat, let card = cards[entity.id], !painting.contains(entity.id) else { return }
        painting.insert(entity.id)
        let prompt = EntityStore.imagePrompt(for: entity.kind, card: card, style: style, details: details)
        Task {
            if let (image, usage) = try? await imageChat.image(prompt: prompt),
               let jpeg = CoverImage.thumbnail(from: image, maxPixelSize: 1024) {
                images[entity.id] = jpeg
                folder.saveImage(jpeg, for: entity)
                book.recordEntityUsage(usage)
            }
            painting.remove(entity.id)
        }
    }

    /// Describes the entity without naming it or the book, so the picture isn't a film or brand likeness.
    /// Adults (per the text) are shown at their most attractive; anyone else gets a plain portrait.
    nonisolated static func imagePrompt(for kind: Entity.Kind, card: EntityCard, style: ImageStyle? = nil, details: String = "") -> String {
        let subject = card.appearance ?? [card.role, card.traits.joined(separator: ", ")].compactMap { $0?.nonEmpty }.joined(separator: "; ")
        let extra = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let additions = extra.isEmpty ? "" : " Also: \(extra)."
        switch kind {
        case .person:
            let look = card.isAdult == true
                ? "Head-and-shoulders portrait of a strikingly attractive adult character from a novel, shown at their most alluring and glamorous: confident gaze, flattering light, styled hair and wardrobe."
                : "Head-and-shoulders portrait of a character from a novel"
            return "\(look): \(subject).\(additions) \((style ?? .photo).phrase) Plain dark background. No text or lettering."
        case .org:
            let rendering = style.map { "\($0.phrase) " } ?? "A single centred insignia, flat muted colours. "
            return "Emblem for a fictional organization in a novel: \(subject).\(additions) \(rendering)Plain dark background. No text or lettering."
        }
    }
}
