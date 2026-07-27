import Fluent

// MARK: - CreateWordDefinition
// Server-side cache of kid-friendly, one-sentence word definitions generated
// by GPT (POST /words/define). Words are stored lowercased; the unique index
// makes the word the natural lookup key and is the backstop for concurrent
// insert races (a lost race is simply ignored — the cached row wins).

struct CreateWordDefinition: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("word_definitions")
            .id()
            .field("word",       .string, .required)
            .field("definition", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "word")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("word_definitions").delete()
    }
}
