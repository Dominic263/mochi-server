import Vapor
import Fluent

// MARK: - WordsController
//
// Kid-friendly one-sentence word definitions for the Mochi journey / word
// collection screens. Sits behind AccountAuthMiddleware.
//
//   POST /words/define — body { "words": ["cat", "harmonica", ...] }
//                        → { "definitions": { "cat": "...", ... } }
//
// Words are lowercased + trimmed and capped at 25 per request. Definitions
// are cached forever in word_definitions, so each distinct word costs exactly
// ONE batched GPT call across the entire player base. If the GPT call fails,
// whatever was cached is returned and the rest are omitted — the client
// simply retries later.

struct WordsController: RouteCollection {

    /// Most words a single request may resolve.
    static let maxWordsPerRequest = 25

    /// Longest stored word (defense against garbage input).
    static let maxWordLength = 40

    /// Hard cap on a stored definition.
    static let maxDefinitionLength = 160

    func boot(routes: any RoutesBuilder) throws {
        let words = routes
            .grouped("words")
            .grouped(AccountAuthMiddleware())
        words.post("define", use: define)
    }

    // MARK: - POST /words/define

    func define(req: Request) async throws -> DefinitionsResponse {
        struct Body: Content {
            let words: [String]
        }
        let body = try req.content.decode(Body.self)

        // Normalize: lowercase + trim, drop blanks/oversized, de-dupe
        // preserving order, cap at 25.
        var seen = Set<String>()
        var words: [String] = []
        for raw in body.words {
            let word = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !word.isEmpty,
                  word.count <= Self.maxWordLength,
                  seen.insert(word).inserted
            else { continue }
            words.append(word)
            if words.count == Self.maxWordsPerRequest { break }
        }
        guard !words.isEmpty else {
            return DefinitionsResponse(definitions: [:])
        }

        // Cached rows first.
        let cached = try await WordDefinition.query(on: req.db)
            .filter(\.$word ~~ words)
            .all()
        var definitions: [String: String] = [:]
        for row in cached {
            definitions[row.word] = row.definition
        }

        let missing = words.filter { definitions[$0] == nil }
        guard !missing.isEmpty else {
            return DefinitionsResponse(definitions: definitions)
        }

        // One batched GPT call for everything we don't have yet. Any failure
        // (no key, network, unparseable output) degrades to cached-only.
        guard let openAIKey = Environment.get("OPENAI_API_KEY") else {
            req.logger.warning("📖 [words/define] OPENAI_API_KEY unset — returning cached only")
            return DefinitionsResponse(definitions: definitions)
        }

        let openAI = OpenAIClient(apiKey: openAIKey, client: req.application.client)
        let raw: String
        do {
            raw = try await openAI.chat(
                system: """
                    You write dictionary definitions for a word game played by kids.
                    For EACH word in the list you receive, write ONE friendly sentence
                    (under 140 characters) that a 7-year-old would understand, saying
                    what the thing is. Never use the word itself in its definition.
                    Output exactly one line per word, in this format and nothing else:
                    word: definition
                    No numbering, no blank lines, no commentary.
                    """,
                messages: [OpenAIClient.Message(role: "user", content: missing.joined(separator: "\n"))],
                maxTokens: min(2000, 60 * missing.count + 50),
                temperature: 0.4
            )
        } catch {
            req.logger.warning("📖 [words/define] GPT call failed — returning cached only: \(error)")
            return DefinitionsResponse(definitions: definitions)
        }

        // Parse "word: definition" lines, store, and fold into the response.
        // Only words we actually asked for are accepted (the model can't
        // inject arbitrary cache rows).
        let missingSet = Set(missing)
        for line in raw.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let word = line[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•*\" "))
                .lowercased()
            let definition = String(
                line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(Self.maxDefinitionLength)
            )
            guard missingSet.contains(word), !definition.isEmpty,
                  definitions[word] == nil
            else { continue }

            definitions[word] = definition

            do {
                try await WordDefinition(word: word, definition: definition).save(on: req.db)
            } catch {
                // Lost a race on the unique index (another request cached the
                // same word concurrently) — fine, the definition still ships.
                req.logger.debug("📖 [words/define] cache insert skipped for '\(word)': \(error)")
            }
        }

        return DefinitionsResponse(definitions: definitions)
    }
}

// MARK: - Response DTO

struct DefinitionsResponse: Content {
    let definitions: [String: String]
}
