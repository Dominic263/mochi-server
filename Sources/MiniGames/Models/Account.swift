
import Fluent
import Vapor

// MARK: - Account
// The canonical server-side identity for a player. Created silently on first
// launch as an ANONYMOUS "shadow" account (no real-world identity attached),
// and later upgraded to LINKED when the user signs in with Apple — without the
// id ever changing. Because the id is stable across that transition, sign-in is
// a LINK (fill in the Apple fields, flip the status) rather than a data
// migration. Everything downstream — game history, friends, ranking — will
// reference this id.
//
// S1 scope: identity only. No profile/cosmetic fields yet (those stay client-
// side for now and may sync in a later version). The opaque session token is a
// placeholder for S1/S3 so the client can authenticate subsequent calls; it
// will be replaced by proper JWT in S2 (Sign in with Apple).

final class Account: Model, Content, @unchecked Sendable {
    static let schema = "accounts"

    @ID(key: .id)
    var id: UUID?

    /// "anonymous" or "linked". See AccountStatus.
    @Field(key: "status")
    var status: String

    /// Display name carried up from the client profile. Nullable until set.
    @OptionalField(key: "display_name")
    var displayName: String?

    /// The stable Apple `sub` identifier. Null until Sign in with Apple (S2).
    /// Unique when present (enforced in the migration) so a given Apple identity
    /// maps to exactly one account.
    @OptionalField(key: "apple_user_id")
    var appleUserID: String?

    /// Apple-relayed email, if the user chooses to share it. Null otherwise.
    @OptionalField(key: "apple_email")
    var appleEmail: String?

    /// Opaque random session token. PLACEHOLDER for S1 — lets the client
    /// authenticate follow-up calls (e.g. S3 progress writes) by sending this
    /// back. Replaced by JWT in S2. Unique so it can be used as a lookup key.
    @Field(key: "session_token")
    var sessionToken: String

    /// One account has many devices (installs). See Device.
    @Children(for: \.$account)
    var devices: [Device]

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        status: AccountStatus = .anonymous,
        displayName: String? = nil,
        sessionToken: String
    ) {
        self.id = id
        self.status = status.rawValue
        self.displayName = displayName
        self.appleUserID = nil
        self.appleEmail = nil
        self.sessionToken = sessionToken
    }
}

// MARK: - Account status

enum AccountStatus: String, Codable, Sendable {
    case anonymous   // shadow account, no real-world identity attached
    case linked      // bound to an Apple identity (S2)
}

extension Account {
    var statusValue: AccountStatus {
        get { AccountStatus(rawValue: status) ?? .anonymous }
        set { status = newValue.rawValue }
    }
}
