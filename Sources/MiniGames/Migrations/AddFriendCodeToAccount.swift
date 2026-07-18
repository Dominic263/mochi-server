import Fluent

// MARK: - AddFriendCodeToAccount
// Adds the nullable `friend_code` column to accounts. Nullable on purpose:
// existing accounts are backfilled LAZILY — the first time an account hits
// GET /friends without a code, one is generated and saved (with retry on
// collision; the unique index below is the backstop for races).

struct AddFriendCodeToAccount: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("accounts")
            .field("friend_code", .string)
            .unique(on: "friend_code")   // Postgres treats multiple NULLs as distinct,
                                         // so un-backfilled accounts don't collide.
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("accounts")
            .deleteUnique(on: "friend_code")
            .deleteField("friend_code")
            .update()
    }
}
