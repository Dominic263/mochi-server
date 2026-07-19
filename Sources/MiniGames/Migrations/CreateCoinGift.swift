import Fluent

// MARK: - CreateCoinGift
// Creates the `coin_gifts` table — the server-side ledger/mailbox for daily
// coin gifts between friends. `claimed_at` stays null until the recipient
// collects the gift.

struct CreateCoinGift: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("coin_gifts")
            .id()
            .field("from_account_id", .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("to_account_id",   .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("amount",          .int, .required)
            .field("created_at",      .datetime)
            .field("claimed_at",      .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("coin_gifts").delete()
    }
}
