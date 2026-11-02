import Foundation
import NaturalLanguage

/// Builds a book's people and organisations: on-device name tagging plus text statistics find
/// candidates, then one LLM call sorts them, drops the rest and merges aliases.
nonisolated enum EntityExtractor {
    struct Candidate: Codable, Sendable, Hashable {
        var name: String
        var mentions: Int
        /// What the on-device tagger mostly called it: "person", "organization", or "".
        var tagged: String
        var snippets: [String]
    }

    @concurrent static func extract(from document: Document, using chat: OpenRouterChat?) async -> (entities: [Entity], usage: LLMUsage) {
        let text = storyText(of: document)
        let found = candidates(in: text)
        guard let chat, !found.isEmpty,
              let (refined, usage) = try? await refine(found, title: document.title, author: document.author, text: text, chat: chat)
        else {
            // Without the LLM, trust the tagger: people it named, organisations it named, nothing else.
            return (found.compactMap { candidate in
                candidate.tagged == "organization" ? Entity(kind: .org, name: candidate.name)
                    : candidate.tagged == "person" ? Entity(kind: .person, name: candidate.name) : nil
            }, LLMUsage())
        }
        return (refined, usage)
    }

    // MARK: Candidates

    /// Chapter text without credits, acknowledgements, adverts and similar front and back matter.
    static func storyText(of document: Document) -> String {
        document.chapters
            .filter { chapter in
                let opening = chapter.title + " " + String(chapter.text.prefix(600))
                return opening.range(of: matterPattern, options: [.regularExpression, .caseInsensitive]) == nil
            }
            .map(\.text)
            .joined(separator: "\n")
    }

    static func candidates(in text: String, limit: Int = 50) -> [Candidate] {
        let ns = text as NSString
        let (taggedPeople, taggedOrgs) = taggedNames(in: text)
        // "Mr. Bennet" and "Mrs. Bennet" both count towards "Bennet".
        let people = taggedPeople.reduce(into: [String: Int]()) { $0[strippingTitle($1.key), default: 0] += $1.value }
        let orgs = taggedOrgs.reduce(into: [String: Int]()) { $0[strippingTitle($1.key), default: 0] += $1.value }

        var proposals = Set(taggedPeople.keys).union(taggedOrgs.keys)
        // Capitalised mid-sentence: catches invented names the tagger doesn't know ("Overse", "Crew").
        for match in midSentenceCapital.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            proposals.insert(ns.substring(with: match.range))
        }
        // CamelCase names ("SecUnit", "DeltFall") that neither of the above sees.
        for match in camelCase.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            proposals.insert(ns.substring(with: match.range))
        }

        let counts = wordCounts(in: text)
        // Five mentions suits a novel; short texts (articles, excerpts) need fewer.
        let minimum = min(5, max(2, ns.length / 40_000))
        var kept: [String: Candidate] = [:]
        for proposal in proposals {
            let name = strippingTitle(proposal)
            guard kept[name] == nil, !stopWords.contains(name), name.count > 1 else { continue }
            let capitalised = name.contains(" ") ? occurrences(of: name, in: text).count : counts[name, default: 0]
            let lowercase = name.contains(" ") ? 0 : counts[name.lowercased(), default: 0]
            guard capitalised >= minimum, lowercase * 3 < capitalised else { continue }
            let asPerson = people[name, default: 0], asOrg = orgs[name, default: 0]
            // A frequent word that is never lowercase is a proper noun even if nothing else says so.
            let properNoun = capitalised >= minimum * 2 && lowercase == 0
            guard asPerson >= min(3, minimum) || asOrg >= 2 || properNoun || agency(of: name, in: text) >= 2 else { continue }
            let hits = occurrences(of: name, in: text)
            let samples = [hits.first, hits.count > 1 ? hits[hits.count / 2] : nil].compactMap { $0 }
            kept[name] = Candidate(name: name, mentions: hits.count,
                                   tagged: asPerson > asOrg ? "person" : asOrg > 0 ? "organization" : "",
                                   snippets: samples.map { snippet(around: $0, in: ns) })
        }
        return kept.values.sorted { $0.mentions > $1.mentions }.prefix(limit).map { $0 }
    }

    private static func taggedNames(in text: String) -> (people: [String: Int], orgs: [String: Int]) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var people: [String: Int] = [:], orgs: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName { people[String(text[range]), default: 0] += 1 }
            if tag == .organizationName { orgs[String(text[range]), default: 0] += 1 }
            return true
        }
        return (people, orgs)
    }

    /// Case-sensitive counts of every word, so "Crew" and "crew" are counted apart.
    private static func wordCounts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in text.split(whereSeparator: { !$0.isLetter && $0 != "-" }) {
            counts[String(word), default: 0] += 1
        }
        return counts
    }

    /// How often the name behaves like a character: speaks, acts, is addressed or possessed.
    private static func agency(of name: String, in text: String) -> Int {
        let n = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?<![\\w-])\(n)(?:’s|'s)? \(verbs)\\b|\\b\(verbs) \(n)\\b|[“,] ?\(n)[,.!?”]|\(n)(?: was| had| is| has| and I| and me)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func occurrences(of name: String, in text: String) -> [Int] {
        let pattern = "(?<![\\w-])\(NSRegularExpression.escapedPattern(for: name))(?![\\w-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range.location)
    }

    private static func strippingTitle(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let first = parts.first, titles.contains(String(first)) else { return name }
        return String(parts.last!)
    }

    static func snippet(around location: Int, in text: NSString, radius: Int = 80) -> String {
        let start = max(0, location - radius)
        let range = NSRange(location: start, length: min(text.length - start, radius * 2))
        return text.substring(with: range).replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: LLM refinement

    private struct Refined: Decodable {
        struct Entry: Decodable {
            var name: String
            var aliases: [String]?
        }
        var people: [Entry]?
        var orgs: [Entry]?
    }

    private static func refine(_ candidates: [Candidate], title: String, author: String?, text: String,
                               chat: OpenRouterChat) async throws -> ([Entity], LLMUsage)? {
        let input = try JSONSerialization.data(withJSONObject: [
            "title": title,
            "author": author ?? "",
            "candidates": candidates.map { ["name": $0.name, "mentions": $0.mentions, "tagged": $0.tagged, "snippets": $0.snippets] },
        ] as [String: Any])
        let reply = try await chat.complete(messages: [
            ["role": "system", "content": refinePrompt],
            ["role": "user", "content": String(decoding: input, as: UTF8.self)],
        ])
        guard let refined = OpenRouterChat.decodeJSON(Refined.self, from: reply.content) else { return nil }
        let people = (refined.people ?? []).map { Entity(kind: .person, name: $0.name, aliases: $0.aliases ?? []) }
        let orgs = (refined.orgs ?? []).map { Entity(kind: .org, name: $0.name, aliases: $0.aliases ?? []) }
        return (validated(people + orgs, in: text), reply.usage)
    }

    /// Keeps only spellings that really occur in the text, each owned by one entity.
    static func validated(_ entities: [Entity], in text: String) -> [Entity] {
        var claimed = Set<String>()
        return entities.compactMap { entity in
            let terms = entity.terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { term in
                guard !term.isEmpty, !claimed.contains(term), occurrences(of: term, in: text).count >= 2 else { return false }
                claimed.insert(term)
                return true
            }
            guard let name = terms.first else { return nil }
            return Entity(kind: entity.kind, name: name, aliases: Array(terms.dropFirst()))
        }
    }

    static let refinePrompt = """
    You clean up an automatically extracted list of candidate names for an e-reader. You get the book's title and author, and candidates with mention counts, what an on-device tagger thought they were, and two context snippets each.

    Return JSON only, in this shape:
    {"people": [{"name": "Elizabeth", "aliases": ["Lizzy", "Miss Bennet"]}],
     "orgs": [{"name": "Pemberley Trust", "aliases": []}]}

    Rules:
    - "people": characters who act or speak in the story, including named animals, AIs and robots.
    - "orgs": organisations that matter in the story: companies, institutions, teams, crews, governments, ships' companies, factions, publishers.
    - Drop places, brands of everyday objects, languages, exclamations ("God"), family words ("Mom"), the author and other credits, and real or mythological figures who are only referred to.
    - Merge candidates that are the same entity. Use the most common form as "name" and list the other forms as "aliases".
    - Add aliases, or major people or organisations missing from the list (such as a narrator who is named only occasionally), only when the snippets make you confident.
    - Every name and alias must be spelled exactly as it appears in the text, including capitalisation. Don't invent spellings.
    - Order each list by importance.
    """

    // MARK: Patterns

    private static let matterPattern = "acknowledg|copyright|about the author|also by|praise for|table of contents|newsletter|discover more|reading group|dedicat"
    private static let verbs = "(?:said|says|asked|asks|replied|whispered|shouted|told|tells|nodded|nods|smiled|smiles|laughed|laughs|looked|looks|turned|turns|walked|walks|sighed|shrugged|grinned|frowned|answered|answers)"
    private static let midSentenceCapital = try! NSRegularExpression(pattern: "(?<=[a-z,;’\"”] )[A-Z][a-z]+(?:-[A-Z][a-z]+)?\\b")
    private static let camelCase = try! NSRegularExpression(pattern: "\\b[A-Z][a-z]+[A-Z][a-z]+\\b")
    private static let titles: Set<String> = ["Dr.", "Dr", "Mr.", "Mr", "Mrs.", "Mrs", "Ms.", "Ms", "Miss", "Colonel", "Captain",
                                              "Professor", "Sir", "Lady", "Lord", "Aunt", "Uncle", "Detective", "Officer"]
    private static let stopWords: Set<String> = [
        "God", "Lord", "Jesus", "Christ", "Heaven", "Hell", "Mom", "Mum", "Mommy", "Dad", "Daddy", "Mother", "Father",
        "Grandma", "Grandpa", "Sir", "Madam", "Dr", "Mr", "Mrs", "Ms", "Miss", "Doctor", "Professor", "Captain", "Colonel",
        "Leader", "Chapter", "Book", "Part", "Prologue", "Epilogue", "English", "Latin", "Greek", "Greeks", "French",
        "German", "Spanish", "Russian", "Chinese", "Japanese", "Korean", "American", "British", "Roman", "Romans",
        "Ages", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February",
        "September", "October", "November", "December", "Christmas", "Okay", "Yes", "No", "Oh", "Sorry", "Hmm", "Um",
        "Thanks", "Please", "Internet", "TV", "OK",
    ]
}
