import Fluent

struct CreateGameResult: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("game_results")
            .id()
            .field("room_code",      .string,  .required)
            .field("game_type",      .string,  .required)
            .field("answerer_id",    .string,  .required)
            .field("questioner_id",  .string,  .required)
            .field("outcome",        .string,  .required)
            .field("secret",         .string,  .required)
            .field("questions_used", .int,     .required)
            .field("created_at",     .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("game_results").delete()
    }
}
