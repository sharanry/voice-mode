import Foundation

/// Minimal OpenRouter client (chat with tool calling, and images) for the people and organisation features.
nonisolated struct OpenRouterChat: Sendable {
    /// Researches entity cards: cheap, and good at tool calling. Reasoning can't be turned off for it.
    static let cardModel = "z-ai/glm-5.3-flash"
    /// Paints portraits of people and emblems of organisations.
    static let imageModel = "recraft/recraft-v4.1-flash"

    var apiKey: String
    var model: String
    /// Some models (GLM) reject requests that disable reasoning; those get low effort instead.
    var canDisableReasoning = true

    /// The configured model (Qwen by default), used to clean up the entity list.
    static func fromSecrets() -> OpenRouterChat? {
        guard let key = Secrets.openRouterAPIKey.nonEmpty else { return nil }
        return OpenRouterChat(apiKey: key, model: Secrets.openRouterModel.nonEmpty ?? OpenRouterDirector.defaultModel)
    }

    static func forImages() -> OpenRouterChat? {
        guard let key = Secrets.openRouterAPIKey.nonEmpty else { return nil }
        return OpenRouterChat(apiKey: key, model: imageModel)
    }

    static func forCards() -> OpenRouterChat? {
        guard let key = Secrets.openRouterAPIKey.nonEmpty else { return nil }
        return OpenRouterChat(apiKey: key, model: cardModel, canDisableReasoning: false)
    }

    struct ToolCall: Sendable {
        var id: String
        var name: String
        var arguments: String
    }

    struct Reply: Sendable {
        var content: String?
        var toolCalls: [ToolCall]
        var usage: LLMUsage

        /// The reply as a message to append to the conversation.
        var message: [String: Any] {
            var message: [String: Any] = ["role": "assistant", "content": content ?? ""]
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls.map {
                    ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                }
            }
            return message
        }
    }

    /// `tools` are OpenAI-style function definitions; pass `allowTools: false` to force a final answer.
    func complete(messages: [[String: Any]], tools: [[String: Any]] = [], allowTools: Bool = true,
                  temperature: Double = 0.2, timeout: TimeInterval = 60) async throws -> Reply {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Voice Mode", forHTTPHeaderField: "X-Title")
        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "reasoning": canDisableReasoning ? ["enabled": false] : ["effort": "low"],
            "usage": ["include": true],
            "messages": messages,
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = allowTools ? "auto" : "none"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DirectorError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any]
        else { throw DirectorError.empty }

        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ToolCall? in
            guard let id = call["id"] as? String, let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            return ToolCall(id: id, name: name, arguments: function["arguments"] as? String ?? "{}")
        }
        let usage = json["usage"] as? [String: Any]
        return Reply(content: message["content"] as? String, toolCalls: calls,
                     usage: LLMUsage(usd: (usage?["cost"] as? NSNumber)?.doubleValue ?? 0,
                                     tokens: (usage?["total_tokens"] as? NSNumber)?.intValue ?? 0))
    }

    /// Generates one square image with an image model (`imageModel`), returning its encoded bytes.
    @concurrent func image(prompt: String, timeout: TimeInterval = 90) async throws -> (Data, LLMUsage) {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Voice Mode", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "modalities": ["image"],
            "image_config": ["aspect_ratio": "1:1"],
            "usage": ["include": true],
            "messages": [["role": "user", "content": prompt]],
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DirectorError.http(status) }
        // The image comes back inline as a data URL.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any],
              let url = (((message["images"] as? [[String: Any]])?.first)?["image_url"] as? [String: Any])?["url"] as? String,
              let comma = url.firstIndex(of: ","), let bytes = Data(base64Encoded: String(url[url.index(after: comma)...]))
        else { throw DirectorError.empty }
        let usage = json["usage"] as? [String: Any]
        return (bytes, LLMUsage(usd: (usage?["cost"] as? NSNumber)?.doubleValue ?? 0,
                                tokens: (usage?["total_tokens"] as? NSNumber)?.intValue ?? 0))
    }

    /// Decodes the first JSON object in a model's answer, tolerating code fences and surrounding prose.
    static func decodeJSON<T: Decodable>(_ type: T.Type, from content: String?) -> T? {
        guard let content, let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end
        else { return nil }
        return try? JSONDecoder().decode(type, from: Data(content[start...end].utf8))
    }
}
