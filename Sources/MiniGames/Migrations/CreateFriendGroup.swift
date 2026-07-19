import Fluent

// MARK: - CreateFriendGroup
// Creates the `friend_groups` table — private leaderboard groups joined via a
// unique 6-character invite code. The owner FK cascades so deleting an account
// deletes the groups it owns (and, transitively, their memberships).

struct CreateFriendGroup: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("friend_groups")
            .id()
            .field("name",        .string, .required)
            .field("icon",        .string, .required)
            .field("color",       .string, .required)
            .field("invite_code", .string, .required)
            .field("owner_id",    .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("created_at",  .datetime)
            .unique(on: "invite_code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("friend_groups").delete()
    }
}
