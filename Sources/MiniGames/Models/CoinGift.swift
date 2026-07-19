import Fluent
import Vapor

// MARK: - CoinGift
// A daily coin gift between friends. Wallets live on the CLIENT — the server
// is only the ledger/mailbox: a row is created when a friend sends a gift
// (one per sender per UTC calendar day, fixed amount) and `claimed_at` is
// stamped when the recipient collects it. Claiming is idempotent.

final class CoinGift: Model, Content, @unchecked Sendable {
    static let schema = "coin_gifts"

    @ID(key: .id)
    var id: UUID?

    /// The account that sent the gift.
    @Parent(key: "from_account_id")
    var from: Account

    /// The friend the gift is addressed to.
    @Parent(key: "to_account_id")
    var to: Account

    /// Coin amount (fixed at 100 by the controller).
    @Field(key: "amount")
    var amount: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    /// When the recipient claimed the gift; nil while it sits in the mailbox.
    @OptionalField(key: "claimed_at")
    var claimedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        fromAccountID: UUID,
        toAccountID: UUID,
        amount: Int
    ) {
        self.id = id
        self.$from.id = fromAccountID
        self.$to.id = toAccountID
        self.amount = amount
    }
}
