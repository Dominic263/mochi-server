import Fluent

// MARK: - CreateFriendship
// Creates the `friendships` table. Directional rows (requester → addressee)
// with a composite unique index preventing duplicates in the same direction;
// the reverse direction is guarded at the controller level before insert.

struct CreateFriendship: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("friendships")
            .id()
            .field("requester_id", .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("addressee_id", .uuid, .required,
                   .references("accounts", "id", onDelete: .cascade))
            .field("status",       .string, .required)
            .field("created_at",   .datetime)
            .field("updated_at",   .datetime)
            .unique(on: "requester_id", "addressee_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("friendships").delete()
    }
}
