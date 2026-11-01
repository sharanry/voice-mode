import CryptoKit
import Foundation

/// On-disk cache of synthesized audio + alignment, keyed by provider identity and exact text,
/// so the same text is never paid for twice.
nonisolated struct TTSCache {
    static let shared = TTSCache(directory: URL.cachesDirectory.appending(path: "tts", directoryHint: .isDirectory))

    let directory: URL

    /// Returns cached audio for `speech.text`, or directs (adds audio tags), synthesizes and caches it.
    /// Marks are always relative to the original, untagged text.
    func clip(for speech: SpeechRequest, provider: some TTSProvider, director: (any ExpressionDirector)?) async throws -> SpeechClip {
        let identity = [provider.cacheIdentity, director?.identity].compactMap { $0 }.joined(separator: "|")
        let key = Self.key(identity: identity, text: speech.text)
        let audioURL = directory.appending(path: "\(key).mp3")
        let marksURL = directory.appending(path: "\(key).json")

        if let data = try? Data(contentsOf: marksURL),
           let marks = try? JSONDecoder().decode([CharMark].self, from: data),
           FileManager.default.fileExists(atPath: audioURL.path()) {
            return SpeechClip(audioURL: audioURL, marks: marks)
        }

        var request = speech
        var offsetMap: [Int]?
        var cost = SpeechCost()
        // Directing is best effort: on any failure, or if the director altered the words, speak the plain text.
        // Its cost counts either way, since the request was made.
        if let director, let direction = try? await director.direct(speech.text) {
            cost.llmUSD = direction.usd
            cost.llmTokens = direction.tokens
            if let map = AudioTags.offsetMap(tagged: direction.text, original: speech.text) {
                request.text = direction.text
                offsetMap = map
            }
        }
        let synthesis = try await provider.synthesize(request)
        cost.ttsCredits = synthesis.credits
        let audio = synthesis.audio
        let marks = offsetMap.map { AudioTags.remap(synthesis.marks, with: $0) } ?? synthesis.marks
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try audio.write(to: audioURL, options: .atomic)
        try JSONEncoder().encode(marks).write(to: marksURL, options: .atomic)
        return SpeechClip(audioURL: audioURL, marks: marks, cost: cost)
    }

    static func key(identity: String, text: String) -> String {
        SHA256.hash(data: Data("\(identity)|\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
