import Foundation
import Vapor

// MARK: - OpenAI Client (server-side)

struct OpenAIClient {

    let apiKey: String
    let model: String
    let client: Client

    init(apiKey: String, model: String = "gpt-4o-mini", client: Client) {
        self.apiKey = apiKey
        self.model = model
        self.client = client
    }

    // MARK: - Chat completion

    func chat(
        system: String,
        messages: [Message],
        maxTokens: Int = 200,
        temperature: Double = 0.7
    ) async throws -> String {
        struct RequestBody: Content {
            let model: String
            let messages: [Message]
            let max_tokens: Int
            let temperature: Double
        }

        struct ResponseBody: Content {
            struct Choice: Content {
                struct Message: Content {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        var allMessages = [Message(role: "system", content: system)]
        allMessages.append(contentsOf: messages)

        let body = RequestBody(
            model: model,
            messages: allMessages,
            max_tokens: maxTokens,
            temperature: temperature
        )

        let response = try await client.post(
            URI(string: "https://api.openai.com/v1/chat/completions")
        ) { req in
            req.headers.add(name: .authorization, value: "Bearer \(apiKey)")
            req.headers.contentType = .json
            try req.content.encode(body)
        }

        let parsed = try response.content.decode(ResponseBody.self)
        guard let content = parsed.choices.first?.message.content else {
            throw Abort(.internalServerError, reason: "No response from OpenAI")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Message: Content {
        let role: String
        let content: String
    }
}
