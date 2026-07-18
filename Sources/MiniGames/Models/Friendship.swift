import Fluent
import Vapor

// MARK: - Friendship
// One row per friend relationship (or pending request). The row is directional:
// `requester` sent the request, `addressee` received it. Once accepted the
// direction stops mattering — both sides are "friends". Declining or
// unfriending DELETES the row (no tombstones), so a fresh request can always
// be sent again later.
//
// A unique composite index on (requester_id, addressee_id) prevents duplicate
// rows in the same direction; the reverse direction is guarded in the
// controller (checked before insert).

final class Friendship: Model, Content, @unchecked Sendable {
    static let schema = "friendships"

    @ID(key: .id)
    var id: UUID?

    /// The account that sent the friend request.
    @Parent(key: "requester_id")
    var requester: Account

    /// The account the request was sent to.
    @Parent(key: "addressee_id")
    var addressee: Account

    /// "pending" or "accepted". See FriendshipStatus.
    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        requesterID: UUID,
        addresseeID: UUID,
        status: FriendshipStatus = .pending
    ) {
        self.id = id
        self.$requester.id = requesterID
        self.$addressee.id = addresseeID
        self.status = status.rawValue
    }
}

// MARK: - Friendship status

enum FriendshipStatus: String, Codable, Sendable {
    case pending    // request sent, awaiting the addressee's response
    case accepted   // both sides are friends
}

// MARK: - Membership helpers

extension Friendship {
    /// Is the given account one of the two sides of this friendship?
    func involves(_ accountID: UUID) -> Bool {
        $requester.id == accountID || $addressee.id == accountID
    }

    /// The account id on the OTHER side of this friendship, or nil if the
    /// given account isn't a member at all.
    func otherAccountID(besides accountID: UUID) -> UUID? {
        if $requester.id == accountID { return $addressee.id }
        if $addressee.id == accountID { return $requester.id }
        return nil
    }
}
