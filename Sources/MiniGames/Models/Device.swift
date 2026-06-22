import Fluent
import Vapor

// MARK: - Device
// Maps one app install (one physical device's local profile) to an Account.
// The relationship is one-account-to-many-devices: an account can accumulate
// several devices over its life (e.g. the user signs in with Apple on a second
// phone, and that phone's Device row gets attached to the SAME account).
//
// `clientPlayerID` is the client's local UUID — the same opaque string that
// today flows through the game as answererID / questionerID. It is UNIQUE: one
// install maps to exactly one device row. Before sign-in, each fresh install
// (new device OR a delete-reinstall) is its own anonymous account, because the
// client UUID is all the server has to go on; only Sign in with Apple (S2) lets
// multiple devices converge on one account.

final class Device: Model, Content, @unchecked Sendable {
    static let schema = "devices"

    @ID(key: .id)
    var id: UUID?

    /// The account this device belongs to. Reassignable: on Apple sign-in, a
    /// device first bootstrapped onto an orphan anonymous account gets moved to
    /// the canonical account for that Apple identity.
    @Parent(key: "account_id")
    var account: Account

    /// The client's local UUID (today's answererID / questionerID). Unique.
    @Field(key: "client_player_id")
    var clientPlayerID: String

    /// Manually updated on each bootstrap call. Plain optional date (not a
    /// @Timestamp trigger) since we set it explicitly.
    @OptionalField(key: "last_seen_at")
    var lastSeenAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, accountID: UUID, clientPlayerID: String, lastSeenAt: Date? = Date()) {
        self.id = id
        self.$account.id = accountID
        self.clientPlayerID = clientPlayerID
        self.lastSeenAt = lastSeenAt
    }
}
