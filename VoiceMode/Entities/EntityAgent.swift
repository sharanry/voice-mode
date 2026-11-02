import Foundation

/// grep / read / list_chapters over a book, limited to the text up to `limit` so nothing the reader
/// hasn't reached can leak into a card.
nonisolated struct BookTools: Sendable {
    let document: Document
    let limit: ReadingPosition

    func visibleText(ofChapter index: Int) -> String {
        guard document.chapters.indices.contains(index), index <= limit.chapter else { return "" }
        let text = document.chapters[index].text
        guard index == limit.chapter else { return text }
        let ns = text as NSString
        return ns.substring(to: min(max(limit.offset, 0), ns.length))
    }

    /// Up to `maxResults` matches spread evenly across everything visible, so results cover the whole story so far.
    func grep(_ pattern: String, maxResults: Int = 8) -> String {
        let regex = (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
            ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: .caseInsensitive))
        guard let regex else { return "Invalid pattern." }
        var hits: [(chapter: Int, location: Int)] = []
        for index in 0...min(limit.chapter, document.chapters.count - 1) {
            let text = visibleText(ofChapter: index)
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                hits.append((index, match.range.location))
            }
        }
        guard !hits.isEmpty else { return "No matches." }
        let step = max(1, Double(hits.count) / Double(max(maxResults, 1)))
        let picks = stride(from: 0.0, to: Double(hits.count), by: step).prefix(maxResults).map { hits[Int($0)] }
        let lines = picks.map { hit in
            let snippet = EntityExtractor.snippet(around: hit.location, in: visibleText(ofChapter: hit.chapter) as NSString, radius: 160)
            return "[chapter \(hit.chapter) “\(document.chapters[hit.chapter].title)”, offset \(hit.location)] …\(snippet)…"
        }
        return "\(hits.count) matches; showing \(picks.count):\n" + lines.joined(separator: "\n")
    }

    func read(chapter: Int, offset: Int, length: Int = 1500) -> String {
        let text = visibleText(ofChapter: chapter) as NSString
        guard text.length > 0 else { return "That chapter isn't available." }
        let start = min(max(offset, 0), text.length)
        return text.substring(with: NSRange(location: start, length: min(min(max(length, 1), 2000), text.length - start)))
    }

    func listChapters() -> String {
        (0...min(limit.chapter, document.chapters.count - 1))
            .map { "\($0): \(document.chapters[$0].title) (\((visibleText(ofChapter: $0) as NSString).length) characters)" }
            .joined(separator: "\n")
    }

    func run(_ call: OpenRouterChat.ToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue ?? (args[key] as? String).flatMap { Int($0) } }
        switch call.name {
        case "grep": return grep(args["pattern"] as? String ?? "", maxResults: min(int("max_results") ?? 8, 12))
        case "read": return read(chapter: int("chapter") ?? limit.chapter, offset: int("offset") ?? 0, length: int("length") ?? 1500)
        case "list_chapters": return listChapters()
        default: return "Unknown tool \(call.name)."
        }
    }

    nonisolated(unsafe) static let definitions: [[String: Any]] = [ // immutable
        function("grep", "Case-insensitive regex search over the book so far. Returns matches spread across the text, each with its chapter, offset and surrounding text.",
                 ["pattern": ["type": "string"], "max_results": ["type": "integer", "description": "1-12, default 8"]], required: ["pattern"]),
        function("read", "Read a passage of the book so far.",
                 ["chapter": ["type": "integer"], "offset": ["type": "integer"], "length": ["type": "integer", "description": "Up to 2000 characters"]],
                 required: ["chapter", "offset"]),
        function("list_chapters", "List the chapters read so far.", [:], required: []),
    ]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }
}

/// Researches one person or organisation with a short tool-calling loop and writes its card.
nonisolated enum EntityAgent {
    static let maxToolTurns = 4

    enum Failure: Error { case noAnswer }

    /// `known` is every entity in the book, so relationships use the names the app can link.
    @concurrent static func research(_ entity: Entity, known: [Entity], in document: Document, through limit: ReadingPosition,
                                     previous: EntityCard?, chat: OpenRouterChat) async throws -> (EntityCard, LLMUsage) {
        let tools = BookTools(document: document, limit: limit)
        let pattern = entity.terms.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let others = Entity.Kind.allCases.map { kind in
            "\(kind.title): " + known.filter { $0.kind == kind && $0 != entity }.map(\.name).joined(separator: ", ")
        }
        var brief = """
        Book: \(document.title)\(document.author.map { " by \($0)" } ?? "")
        \(entity.kind == .person ? "Person" : "Organization"): \(entity.name)\(entity.aliases.isEmpty ? "" : " (also: \(entity.aliases.joined(separator: ", ")))")
        The reader is in chapter \(limit.chapter) “\(document.chapters[limit.chapter].title)” of \(document.chapters.count). The tools only show text up to there.
        Others in the book (use these exact names in relationships):
        \(others.joined(separator: "\n"))

        Mentions so far (grep "\(pattern)"):
        \(tools.grep("(?-i)\(pattern)", maxResults: 12))
        """
        if let previous, let data = try? JSONEncoder().encode(previous) {
            brief += "\n\nYour earlier card, written at chapter \(previous.through.chapter). Update it with what happens after that:\n\(String(decoding: data, as: UTF8.self))"
        }

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt(for: entity.kind)], ["role": "user", "content": brief]]
        var usage = LLMUsage()
        for _ in 0..<maxToolTurns {
            try Task.checkCancellation()
            let reply = try await chat.complete(messages: messages, tools: BookTools.definitions)
            usage = usage + reply.usage
            if reply.toolCalls.isEmpty, let card = card(from: reply.content, limit: limit) { return (card, usage) }
            messages.append(reply.message)
            for call in reply.toolCalls {
                messages.append(["role": "tool", "tool_call_id": call.id, "content": String(tools.run(call).prefix(6000))])
            }
            if reply.toolCalls.isEmpty { break }
        }
        messages.append(["role": "user", "content": "Stop researching and answer now with the JSON card only."])
        let reply = try await chat.complete(messages: messages, tools: BookTools.definitions, allowTools: false)
        usage = usage + reply.usage
        guard let card = card(from: reply.content, limit: limit) else { throw Failure.noAnswer }
        return (card, usage)
    }

    private struct Draft: Decodable {
        var summary: String
        var role: String?
        var traits: [String]?
        var relationships: [EntityCard.Relationship]?
        var moments: [EntityCard.Moment]?
        var appearance: String?
        var adult: LenientBool?
    }

    /// Accepts true/false, "yes"/"no" and similar, so one odd field can't sink the whole card.
    private struct LenientBool: Decodable {
        var value: Bool?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let text = try? container.decode(String.self) {
                value = ["true", "yes"].contains(text.lowercased()) ? true : ["false", "no"].contains(text.lowercased()) ? false : nil
            }
        }
    }

    static func card(from content: String?, limit: ReadingPosition) -> EntityCard? {
        guard let draft = OpenRouterChat.decodeJSON(Draft.self, from: content), !draft.summary.isEmpty else { return nil }
        // Moments must point at text the reader has already seen.
        let moments = (draft.moments ?? []).filter {
            $0.chapter >= 0 && ($0.chapter < limit.chapter || ($0.chapter == limit.chapter && $0.offset <= limit.offset))
        }
        return EntityCard(summary: draft.summary, role: draft.role?.nonEmpty, traits: draft.traits ?? [],
                          relationships: draft.relationships ?? [], moments: moments,
                          appearance: draft.appearance?.nonEmpty, isAdult: draft.adult?.value, through: limit)
    }

    static func systemPrompt(for kind: Entity.Kind) -> String {
        let person = kind == .person
        return """
        You write a card about \(person ? "a character" : "an organization") for an e-reader, describing \(person ? "them" : "it") as of where the reader has got to.

        Use the tools to research: grep for the names, for the \(person ? "people" : "members") around \(person ? "them" : "it") and for key events, and read passages that matter. Be efficient: a few targeted calls are enough.

        Strict rules:
        - Use only what the tools show. Even if you recognise the book, never use outside knowledge: the reader hasn't read further, and anything beyond the visible text is a spoiler.
        - Be concrete and brief. No hedging and no literary analysis.

        When you're done, reply with JSON only:
        {"summary": "2-3 sentences: \(person ? "who they are and where they stand now" : "what it is, what it wants and its part in the story so far")",
         "role": "\(person ? "a few words, e.g. narrator's husband" : "what kind of organization, e.g. mining corporation")",
         "traits": ["up to 4 short \(person ? "traits" : "characteristics")"],
         "relationships": [{"name": "\(person ? "Other person or organization" : "Member, ally or rival")", "relation": "how they're connected"}],
         "moments": [{"chapter": 3, "offset": 1203, "note": "what happens there"}],
         "appearance": "\(person ? "for a photographer: apparent age, gender, build, face, hair, clothing, and the era and setting" : "for a designer: its visual identity, such as uniforms, logo, colours, ships or buildings, and the era and setting")"\(person ? ",\n     \"adult\": true only if the text makes clear they are an adult, false if they are under 18, null if unclear" : "")}
        Give up to 5 moments, in story order, using chapter and offset values from the tool results.
        Base "appearance" on descriptions in the text; where the text is silent, infer only what the \(person ? "role" : "kind of organization") and setting imply. Write only the visual description itself: no remarks about what the text does or doesn't say. Don't name \(person ? "the character" : "the organization") or the book in it.
        """
    }
}
