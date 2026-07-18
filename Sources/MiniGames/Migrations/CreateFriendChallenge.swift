import Fluent

// MARK: - CreateFriendChallenge
// Creates the `friend_challenges` table — short-lived "join my room" pointers
// between friends. Rows are pruned lazily (superseded on re-challenge, deleted
// when the underlying game session leaves the lobby).

struct CreateFriendChallenge: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("friend_challenges")
            .id()
            .field("from_account_id", .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("to_account_id",   .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("room_code",       .string, .required)
            .field("status",          .string, .required)
            .field("created_at",      .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("friend_challenges").delete()
    }
}
