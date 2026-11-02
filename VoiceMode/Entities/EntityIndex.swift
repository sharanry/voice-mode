import Foundation

/// Finds every mention of a book's entities by exact, whole-word matching of their names and aliases.
nonisolated struct EntityIndex: Sendable {
    let entities: [Entity]
    private let regex: NSRegularExpression?
    private let owner: [String: Int]

    init(entities: [Entity]) {
        self.entities = entities
        var owner: [String: Int] = [:]
        for (index, entity) in entities.enumerated() {
            for term in entity.terms where !term.isEmpty && owner[term] == nil { owner[term] = index }
        }
        self.owner = owner
        // Longest first, so "Dr. Mensah" wins over "Mensah".
        let alternatives = owner.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        regex = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}-])(?:\(alternatives.joined(separator: "|")))(?![\\p{L}\\p{N}]|-\\p{L})")
    }

    func mentions(in text: String) -> [Mention] {
        guard let regex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            owner[ns.substring(with: match.range)].map { Mention(range: match.range, entity: $0) }
        }
    }
}
