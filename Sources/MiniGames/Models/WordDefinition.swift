import Fluent
import Vapor

// MARK: - WordDefinition
// One cached kid-friendly definition per (lowercased) word. Written the first
// time any player requests the word via POST /words/define; read forever after
// so each word costs exactly one GPT call across the whole player base.

final class WordDefinition: Model, Content, @unchecked Sendable {
    static let schema = "word_definitions"

    @ID(key: .id)
    var id: UUID?

    /// Lowercased, trimmed word — unique (see CreateWordDefinition).
    @Field(key: "word")
    var word: String

    /// Kid-friendly one-sentence definition, ≤160 chars.
    @Field(key: "definition")
    var definition: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(word: String, definition: String) {
        self.word = word
        self.definition = definition
    }
}
