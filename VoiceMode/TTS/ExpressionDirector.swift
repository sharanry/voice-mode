import Foundation

/// Rewrites a passage with ElevenLabs audio tags ("[excited]", "[sighs]"…) so narration
/// carries emotion. Implementations must only insert tags; `AudioTags.offsetMap` enforces it.
nonisolated protocol ExpressionDirector: Sendable {
    var identity: String { get }
    func direct(_ text: String) async throws -> Direction
}

nonisolated struct Direction: Sendable {
    var text: String
    /// Dollars charged for the request, as reported by the provider.
    var usd: Double
    var tokens: Int
}

nonisolated struct OpenRouterDirector: ExpressionDirector {
    static let defaultModel = "qwen/qwen3.8-27b"

    var apiKey: String
    var model = defaultModel

    var identity: String { "openrouter:\(model):v1" }

    static func fromSecrets() -> OpenRouterDirector? {
        guard let key = Secrets.openRouterAPIKey.nonEmpty else { return nil }
        return OpenRouterDirector(apiKey: key, model: Secrets.openRouterModel.nonEmpty ?? defaultModel)
    }

    func direct(_ text: String) async throws -> Direction {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Voice Mode", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0.3,
            "reasoning": ["enabled": false],
            "usage": ["include": true], // ask OpenRouter to report the request's dollar cost
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text],
            ],
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DirectorError.http(status) }
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = body.choices.first?.message.content?.nonEmpty else { throw DirectorError.empty }
        return Direction(text: content, usd: body.usage?.cost ?? 0, tokens: body.usage?.totalTokens ?? 0)
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        struct Usage: Decodable {
            var cost: Double?
            var totalTokens: Int?
            enum CodingKeys: String, CodingKey {
                case cost
                case totalTokens = "total_tokens"
            }
        }
        var choices: [Choice]
        var usage: Usage?
    }

    static let systemPrompt = """
    You are the voice director for an audiobook narrated with ElevenLabs. Insert audio tags in square brackets so the narrator performs the passage with natural emotion.

    Rules:
    - Return the passage with tags inserted and nothing else. Never add, remove, reorder or change any word, punctuation mark or line break of the original.
    - Put each tag immediately before the words it colours, followed by a space, e.g. [excited] “Oh!” or [sighs] I suppose so.
    - Use short, performable tags: emotions and delivery ([excited], [warmly], [sarcastically], [impatiently], [nervously], [dryly], [softly], [whispers], [shouting]) and sparing non-verbal sounds ([sighs], [laughs], [chuckles], [gasps]).
    - Tag mainly dialogue and emotionally charged lines. Plain narration usually needs no tag. Prefer zero or one tag per sentence; never stack tags.
    - Take cues from the text itself (speech verbs and adverbs like "cried impatiently", punctuation, context).
    - Speech attributions such as "said she" or "cried his wife impatiently" are part of the text and must stay exactly where they are.

    Example input:
    “Is it true?” asked Jane quietly. He shook his head.
    Example output:
    [quietly] “Is it true?” asked Jane quietly. [sadly] He shook his head.
    """
}

nonisolated enum DirectorError: Error {
    case http(Int)
    case empty
}

nonisolated enum AudioTags {
    private static let maxTagLength = 40

    /// Maps every UTF-16 offset in `tagged` (plus its end) to an offset in `original`, or returns
    /// nil if `tagged` is anything other than `original` with bracketed tags and whitespace inserted.
    /// Tag characters map to the position of the text that follows them.
    static func offsetMap(tagged: String, original: String) -> [Int]? {
        let t = Array(tagged.utf16), o = Array(original.utf16)
        var map: [Int] = []
        map.reserveCapacity(t.count + 1)
        var i = 0, j = 0
        while i < t.count {
            if j < o.count, t[i] == o[j] {
                map.append(j)
                i += 1
                j += 1
            } else if let end = tagEnd(in: t, from: i) {
                map.append(contentsOf: repeatElement(j, count: end - i + 1))
                i = end + 1
            } else if isSpace(t[i]) {
                map.append(j)
                i += 1
            } else if j < o.count, isSpace(o[j]) {
                j += 1
            } else {
                return nil
            }
        }
        while j < o.count, isSpace(o[j]) { j += 1 }
        guard j == o.count else { return nil }
        map.append(j)
        return map
    }

    /// Re-bases alignment marks from tagged-text offsets onto original-text offsets.
    static func remap(_ marks: [CharMark], with map: [Int]) -> [CharMark] {
        marks.map { CharMark(offset: map[min(max($0.offset, 0), map.count - 1)], start: $0.start) }
    }

    private static func tagEnd(in t: [UInt16], from start: Int) -> Int? {
        guard t[start] == 0x5B else { return nil } // "["
        var k = start + 1
        while k < t.count, k - start <= maxTagLength {
            if t[k] == 0x5D { return k > start + 1 ? k : nil } // "]"
            if t[k] == 0x0A || t[k] == 0x5B { return nil }
            k += 1
        }
        return nil
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0xA0
    }
}
