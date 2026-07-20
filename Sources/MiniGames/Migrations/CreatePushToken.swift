import Fluent

// MARK: - CreatePushToken
// Creates the `push_tokens` table — APNs device tokens per account. The token
// itself is unique (an install's token can only deliver to one account at a
// time); rows are deleted reactively when APNs reports the token dead.

struct CreatePushToken: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("push_tokens")
            .id()
            .field("account_id", .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("token",      .string, .required)
            .field("is_sandbox", .bool, .required)
            .field("updated_at", .datetime)
            .unique(on: "token")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("push_tokens").delete()
    }
}
