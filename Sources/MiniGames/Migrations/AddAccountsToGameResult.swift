import Fluent

// MARK: - AddAccountsToGameResult  (S3)
// Adds nullable account references to game_results so finished games can be
// attributed to accounts (per-account stats/history) rather than raw client
// UUIDs. Both sides are nullable because:
//   • the AI side has no account (its id is an ephemeral UUID, no device row), and
//   • rows written before accounts existed (S1) have no account to resolve.
// Old rows simply stay null — they predate accounts and aren't backfilled.

struct AddAccountsToGameResult: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("game_results")
            .field("answerer_account_id",   .uuid,
                   .references("accounts", "id", onDelete: .setNull))
            .field("questioner_account_id", .uuid,
                   .references("accounts", "id", onDelete: .setNull))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("game_results")
            .deleteField("answerer_account_id")
            .deleteField("questioner_account_id")
            .delete()
    }
}
