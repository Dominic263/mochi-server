import Fluent

// MARK: - CreateFriendGroupMember
// Creates the `friend_group_members` table. A composite unique index on
// (group_id, account_id) prevents double-joins; both FKs cascade so deleting a
// group or an account sweeps the membership rows away.

struct CreateFriendGroupMember: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("friend_group_members")
            .id()
            .field("group_id",   .uuid, .required,
                   .references("friend_groups", "id", onDelete: .cascade))
            .field("account_id", .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("joined_at",  .datetime)
            .unique(on: "group_id", "account_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("friend_group_members").delete()
    }
}
