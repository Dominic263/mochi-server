import Fluent
import Vapor

// MARK: - FriendGroup
// A private leaderboard group. Anyone with the 6-character invite code (same
// unambiguous alphabet as friend codes) can join. The creator is the owner and
// auto-joins on creation; if the owner leaves, the whole group is deleted
// (memberships cascade away with it).

final class FriendGroup: Model, Content, @unchecked Sendable {
    static let schema = "friend_groups"

    @ID(key: .id)
    var id: UUID?

    /// Display name, max 30 characters (enforced in the controller).
    @Field(key: "name")
    var name: String

    /// Client-chosen icon identifier (e.g. an SF Symbol or emoji).
    @Field(key: "icon")
    var icon: String

    /// Client-chosen color identifier (e.g. a hex string or palette name).
    @Field(key: "color")
    var color: String

    /// Shareable 6-character join code, unique across all groups.
    @Field(key: "invite_code")
    var inviteCode: String

    /// The account that created (and administers) the group.
    @Parent(key: "owner_id")
    var owner: Account

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        icon: String,
        color: String,
        inviteCode: String,
        ownerID: UUID
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.inviteCode = inviteCode
        self.$owner.id = ownerID
    }
}
