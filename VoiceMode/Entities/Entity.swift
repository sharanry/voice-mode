import Foundation

/// A person or organisation found in a book, with every spelling the text uses for it.
nonisolated struct Entity: Codable, Sendable, Hashable, Identifiable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case person, org

        /// Folder under `entities/`, e.g. `entities/people/`.
        var folder: String { self == .person ? "people" : "orgs" }
        var title: String { self == .person ? "People" : "Organizations" }
    }

    var kind: Kind
    var name: String
    /// Other exact spellings that refer to the same entity ("Low", "Dr. Mensah").
    var aliases: [String] = []

    /// Also its path under `entities/`, e.g. `people/mensah`.
    var id: String { "\(kind.folder)/\(slug)" }
    /// Everything that gets underlined in the text.
    var terms: [String] { [name] + aliases }

    var slug: String {
        let parts = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return parts.isEmpty ? "unnamed" : parts.joined(separator: "-")
    }
}

/// What the research loop learned about an entity, from the text up to `through`.
nonisolated struct EntityCard: Codable, Sendable, Hashable {
    struct Relationship: Codable, Sendable, Hashable {
        var name: String
        var relation: String
    }

    struct Moment: Codable, Sendable, Hashable {
        var chapter: Int
        var offset: Int
        var note: String
    }

    var summary: String
    /// A person's role, or an organisation's type.
    var role: String?
    var traits: [String] = []
    var relationships: [Relationship] = []
    var moments: [Moment] = []
    /// What they look like (a person) or their visual identity (an organisation), for an illustrator.
    var appearance: String?
    /// True only when the text makes clear a person is an adult; gates the glamorous portrait style.
    var isAdult: Bool?
    /// The reading position the card was written for. Nothing after it was visible to the model.
    var through: ReadingPosition
}

/// How a picture is drawn. People default to a modern photograph; organisations to a flat emblem.
nonisolated enum ImageStyle: String, CaseIterable, Sendable, Identifiable {
    case photo, painterly, anime, watercolor, noir

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: "Photo"
        case .painterly: "Painting"
        case .anime: "Anime"
        case .watercolor: "Watercolor"
        case .noir: "Noir"
        }
    }

    var phrase: String {
        switch self {
        case .photo: "A real, modern photograph: shot on a full-frame camera with an 85mm lens, natural skin texture, shallow depth of field, editorial lighting. Photorealistic, not an illustration."
        case .painterly: "Muted painterly illustration, soft light."
        case .anime: "Clean modern anime illustration, cel shading."
        case .watercolor: "Loose watercolor illustration on textured paper."
        case .noir: "High-contrast black and white film photograph, dramatic shadows."
        }
    }
}

/// One underlined occurrence of an entity in a chapter.
nonisolated struct Mention: Sendable, Hashable {
    var range: NSRange
    /// Index into the book's entity list.
    var entity: Int
}

/// Dollars and tokens an LLM or image step cost.
nonisolated struct LLMUsage: Sendable {
    var usd: Double = 0
    var tokens: Int = 0

    static func + (a: LLMUsage, b: LLMUsage) -> LLMUsage {
        LLMUsage(usd: a.usd + b.usd, tokens: a.tokens + b.tokens)
    }
}

/// A book's entities on disk:
/// ```
/// <Application Support>/Books/<key>/entities/
///   index.json            every person and organisation
///   people/<slug>.json    card    people/<slug>.jpg  portrait
///   orgs/<slug>.json      card    orgs/<slug>.jpg    emblem
/// ```
nonisolated struct EntityFolder: Sendable {
    let book: URL

    init(key: String) {
        let support = URL.applicationSupportDirectory
        book = support.appending(path: "Books/\(key)", directoryHint: .isDirectory)
    }

    var root: URL { book.appending(path: "entities", directoryHint: .isDirectory) }
    private var index: URL { root.appending(path: "index.json") }
    private func file(_ entity: Entity, _ ext: String) -> URL {
        root.appending(path: entity.kind.folder, directoryHint: .isDirectory).appending(path: "\(entity.slug).\(ext)")
    }

    func loadIndex() -> [Entity]? { read([Entity].self, at: index) }
    func saveIndex(_ entities: [Entity]) { write(entities, to: index) }

    func loadCard(_ entity: Entity) -> EntityCard? { read(EntityCard.self, at: file(entity, "json")) }
    func saveCard(_ card: EntityCard, for entity: Entity) { write(card, to: file(entity, "json")) }

    func loadImage(_ entity: Entity) -> Data? { try? Data(contentsOf: file(entity, "jpg")) }
    func saveImage(_ data: Data, for entity: Entity) { put(data, at: file(entity, "jpg")) }

    func remove() { try? FileManager.default.removeItem(at: book) }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) { put(data, at: url) }
    }

    private func put(_ data: Data, at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
