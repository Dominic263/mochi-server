import Fluent
import Vapor

// MARK: - PushToken
// One APNs device token registered for an account. An account can hold several
// tokens (one per install that opted into notifications); a token belongs to
// exactly one account (UNIQUE — re-registering a token that moved to another
// account, e.g. after Apple sign-in on a fresh install, reassigns the row).
//
// `isSandbox` records which APNs environment issued the token (debug builds
// from Xcode get sandbox tokens; TestFlight/App Store get production tokens),
// so PushService can route each send through the matching APNs container.
// Rows are pruned reactively: APNs answering BadDeviceToken/Unregistered
// deletes the row.

final class PushToken: Model, Content, @unchecked Sendable {
    static let schema = "push_tokens"

    @ID(key: .id)
    var id: UUID?

    /// The account this token delivers to.
    @Parent(key: "account_id")
    var account: Account

    /// The hex-encoded APNs device token. Unique across all accounts.
    @Field(key: "token")
    var token: String

    /// True if the token came from the APNs sandbox (development) environment.
    @Field(key: "is_sandbox")
    var isSandbox: Bool

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, accountID: UUID, token: String, isSandbox: Bool) {
        self.id = id
        self.$account.id = accountID
        self.token = token
        self.isSandbox = isSandbox
    }
}
