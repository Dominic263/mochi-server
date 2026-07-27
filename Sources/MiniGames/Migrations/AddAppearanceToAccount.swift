import Fluent

// MARK: - AddAppearanceToAccount
// Adds the player's synced appearance (avatar + equipped cosmetics) and
// progression (xp / level) to accounts. Everything is NULLABLE on purpose:
//
//   • Existing rows (and rows created by old clients that never sync these
//     fields) simply stay NULL — readers coalesce NULL xp to 0 and NULL level
//     to 1, so no backfill and no NOT NULL/default DDL is needed.
//   • Cosmetic ids are CLIENT-defined catalog strings (e.g. "cowboy_hat"),
//     capped at 40 chars at the write sites — the server never validates the
//     catalog.

struct AddAppearanceToAccount: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("accounts")
            .field("avatar_id",         .string)
            .field("equipped_headwear", .string)
            .field("equipped_eyewear",  .string)
            .field("equipped_neckwear", .string)
            .field("xp",                .int)
            .field("level",             .int)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("accounts")
            .deleteField("avatar_id")
            .deleteField("equipped_headwear")
            .deleteField("equipped_eyewear")
            .deleteField("equipped_neckwear")
            .deleteField("xp")
            .deleteField("level")
            .update()
    }
}
