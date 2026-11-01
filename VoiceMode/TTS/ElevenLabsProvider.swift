import Foundation

nonisolated struct ElevenLabsProvider: TTSProvider {
    static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM" // "Rachel", a premade voice
    /// v4 Turbo: as expressive as v4 (understands [audio tags]) at half the credits (~0.2 per character)
    /// and about twice the speed, with the same character alignment.
    static let defaultModelID = "eleven_v4_turbo"

    /// The model narration uses, for display: "eleven_v4_turbo" → "v4 Turbo".
    static var activeModelName: String {
        let id = Secrets.elevenLabsModelID.nonEmpty ?? defaultModelID
        return id.replacingOccurrences(of: "eleven_", with: "")
            .split(separator: "_").map { $0.contains(where: \.isNumber) ? String($0) : $0.capitalized }
            .joined(separator: " ")
    }
    /// Lower stability gives a broader emotional range at some cost to consistency.
    static let stability = 0.4
    /// Neighbouring text sent for continuity; more than this adds cost without helping.
    static let contextLimit = 500

    var apiKey: String
    var voiceID = defaultVoiceID
    var modelID = defaultModelID

    var cacheIdentity: String { "elevenlabs:\(voiceID):\(modelID)" }

    static func fromSecrets() -> ElevenLabsProvider? {
        guard let key = Secrets.elevenLabsAPIKey.nonEmpty else { return nil }
        return ElevenLabsProvider(
            apiKey: key,
            voiceID: Secrets.elevenLabsVoiceID.nonEmpty ?? defaultVoiceID,
            modelID: Secrets.elevenLabsModelID.nonEmpty ?? defaultModelID
        )
    }

    func synthesize(_ speech: SpeechRequest) async throws -> Synthesis {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/with-timestamps?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "text": speech.text,
            "model_id": modelID,
            "voice_settings": ["stability": Self.stability, "similarity_boost": 0.75],
        ]
        if let previous = speech.previousText?.nonEmpty { body["previous_text"] = String(previous.suffix(Self.contextLimit)) }
        if let next = speech.nextText?.nonEmpty { body["next_text"] = String(next.prefix(Self.contextLimit)) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TTSError.http(status, Self.errorMessage(in: data)) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(ResponseBody.self, from: data)
        guard let audio = Data(base64Encoded: result.audioBase64) else { throw TTSError.badAudio }
        // ElevenLabs reports the credits charged in a header; fall back to one per character.
        let credits = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "character-cost").flatMap(Int.init)
            ?? speech.text.count
        return Synthesis(audio: audio, marks: Self.marks(from: result.alignment), credits: credits)
    }

    /// Converts ElevenLabs' per-character alignment into UTF-16 offsets into the request text.
    static func marks(from alignment: Alignment?) -> [CharMark] {
        guard let alignment else { return [] }
        var marks: [CharMark] = []
        var offset = 0
        for (i, character) in alignment.characters.enumerated() {
            if i < alignment.characterStartTimesSeconds.count {
                marks.append(CharMark(offset: offset, start: alignment.characterStartTimesSeconds[i]))
            }
            offset += character.utf16.count
        }
        return marks
    }

    struct Alignment: Decodable {
        var characters: [String]
        var characterStartTimesSeconds: [Double]
    }

    private struct ResponseBody: Decodable {
        var audioBase64: String
        var alignment: Alignment?
    }

    private static func errorMessage(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? [String: Any], let message = detail["message"] as? String { return message }
            if let detail = json["detail"] as? String { return detail }
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }
}

nonisolated enum TTSError: LocalizedError {
    case http(Int, String)
    case badAudio
    case missingKey

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): "Text-to-speech failed (\(status)): \(message)"
        case .badAudio: "Text-to-speech returned unreadable audio."
        case .missingKey: "Add ELEVENLABS_API_KEY to .env and rebuild."
        }
    }
}
