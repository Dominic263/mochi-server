import Fluent

struct CreateGameSession: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("game_sessions")
            .id()
            .field("room_code",     .string,   .required)
            .field("game_type",     .string,   .required)
            .field("answerer_id",   .string,   .required)
            .field("questioner_id", .string)
            .field("state_json",    .string,   .required)
            .field("phase",         .string,   .required)
            .field("created_at",    .datetime)
            .field("updated_at",    .datetime)
            .unique(on: "room_code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("game_sessions").delete()
    }
}
