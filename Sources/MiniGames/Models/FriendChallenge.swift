import Fluent
import Vapor

// MARK: - FriendChallenge
// A lightweight "come play me" pointer. The challenger has ALREADY created a
// game room (POST /game/create — they are the answerer); this row just lets the
// challenged friend DISCOVER that room's code. Rows are short-lived: creating a
// new challenge between the same pair deletes the previous pending one, and
// stale rows (whose game session has left the lobby) are lazily deleted when
// the addressee lists their challenges.

final class FriendChallenge: Model, Content, @unchecked Sendable {
    static let schema = "friend_challenges"

    @ID(key: .id)
    var id: UUID?

    /// The account issuing the challenge (the room's answerer).
    @Parent(key: "from_account_id")
    var from: Account

    /// The friend being challenged.
    @Parent(key: "to_account_id")
    var to: Account

    /// The room code of the already-created game session to join.
    @Field(key: "room_code")
    var roomCode: String

    /// "pending" or "accepted". See FriendChallengeStatus.
    @Field(key: "status")
    var status: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        fromAccountID: UUID,
        toAccountID: UUID,
        roomCode: String,
        status: FriendChallengeStatus = .pending
    ) {
        self.id = id
        self.$from.id = fromAccountID
        self.$to.id = toAccountID
        self.roomCode = roomCode
        self.status = status.rawValue
    }
}

// MARK: - FriendChallenge status

enum FriendChallengeStatus: String, Codable, Sendable {
    case pending    // waiting for the friend to notice / accept
    case accepted   // friend accepted; they join via the normal /game/join
}
