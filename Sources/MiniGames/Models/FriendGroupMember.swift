import Fluent
import Vapor

// MARK: - FriendGroupMember
// One row per (group, account) membership. The composite unique index on
// (group_id, account_id) prevents double-joins; both FKs cascade so deleting a
// group (or an account) sweeps its memberships away automatically.

final class FriendGroupMember: Model, Content, @unchecked Sendable {
    static let schema = "friend_group_members"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "group_id")
    var group: FriendGroup

    @Parent(key: "account_id")
    var account: Account

    @Timestamp(key: "joined_at", on: .create)
    var joinedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        groupID: UUID,
        accountID: UUID
    ) {
        self.id = id
        self.$group.id = groupID
        self.$account.id = accountID
    }
}
