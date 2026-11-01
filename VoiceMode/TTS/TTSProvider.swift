import Foundation

/// When the character at `offset` (UTF-16, relative to the synthesized text) starts being spoken.
nonisolated struct CharMark: Codable, Sendable, Equatable {
    var offset: Int
    var start: TimeInterval
}

/// Text to speak plus its neighbours, which providers use for continuity of intonation.
nonisolated struct SpeechRequest: Sendable {
    var text: String
    var previousText: String?
    var nextText: String?
}

nonisolated struct Synthesis: Sendable {
    var audio: Data
    var marks: [CharMark]
    /// Provider credits charged for this request (ElevenLabs reports them per request).
    var credits: Int
}

nonisolated protocol TTSProvider: Sendable {
    /// Identifies voice/model so cached audio is never reused across them.
    var cacheIdentity: String { get }
    func synthesize(_ request: SpeechRequest) async throws -> Synthesis
}

/// What generating one paragraph cost. Zero when it came from the cache.
nonisolated struct SpeechCost: Sendable, Equatable {
    var ttsCredits = 0
    var llmUSD = 0.0
    var llmTokens = 0

    static let free = SpeechCost()
}

/// Synthesized audio on disk plus its alignment.
nonisolated struct SpeechClip: Sendable {
    var audioURL: URL
    var marks: [CharMark]
    var cost = SpeechCost.free

    /// Start time of the first character at or after `offset`.
    func time(forOffset offset: Int) -> TimeInterval {
        guard !marks.isEmpty else { return 0 }
        var lo = 0, hi = marks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if marks[mid].offset < offset { lo = mid + 1 } else { hi = mid }
        }
        return marks[min(lo, marks.count - 1)].start
    }

    /// Offset of the character being spoken at `time`.
    func offset(atTime time: TimeInterval) -> Int {
        var lo = 0, hi = marks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if marks[mid].start <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? marks[lo - 1].offset : 0
    }
}
