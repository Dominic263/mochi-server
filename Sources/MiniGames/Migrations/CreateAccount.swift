import Fluent

// MARK: - CreateAccount
// Creates the `accounts` and `devices` tables (S1 — identity foundation).
// Both are created in one migration because `devices.account_id` is a foreign
// key into `accounts`, so the parent table must exist first.

struct CreateAccount: AsyncMigration {

    func prepare(on database: any Database) async throws {
        // accounts
        try await database.schema("accounts")
            .id()
            .field("status",        .string, .required)
            .field("display_name",  .string)
            .field("apple_user_id", .string)
            .field("apple_email",   .string)
            .field("session_token", .string, .required)
            .field("created_at",    .datetime)
            .field("updated_at",    .datetime)
            .unique(on: "session_token")
            .unique(on: "apple_user_id")   // Postgres treats multiple NULLs as distinct,
                                           // so anonymous accounts (NULL apple_user_id) don't collide.
            .create()

        // devices
        try await database.schema("devices")
            .id()
            .field("account_id",       .uuid,   .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("client_player_id", .string, .required)
            .field("last_seen_at",     .datetime)
            .field("created_at",       .datetime)
            .unique(on: "client_player_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        // Drop child table first (FK dependency).
        try await database.schema("devices").delete()
        try await database.schema("accounts").delete()
    }
}
