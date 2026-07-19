import Vapor
import Fluent

// MARK: - GiftsController
//
// Daily coin gifts between friends. Wallets are CLIENT-side — the server is
// just the ledger/mailbox: sending creates a row, claiming stamps claimed_at.
// All routes sit behind AccountAuthMiddleware (so `req.account` is available).
//
//   POST /gifts                — send today's gift to a friend (one per sender per UTC day)
//   GET  /gifts/pending        — unclaimed gifts addressed to me, newest first
//   POST /gifts/:giftID/claim  — claim a gift (idempotent)

struct GiftsController: RouteCollection {

    /// Fixed coin amount per gift.
    static let giftAmount = 100

    func boot(routes: any RoutesBuilder) throws {
        let gifts = routes
            .grouped("gifts")
            .grouped(AccountAuthMiddleware())
        gifts.post(use: send)
        gifts.get("pending", use: pending)
        gifts.post(":giftID", "claim", use: claim)
    }

    // MARK: - POST /gifts
    //
    // Body: { "friendshipID": "<uuid>" }
    // The sender must be part of an ACCEPTED friendship; the gift goes to the
    // other side. One gift per sender per UTC calendar day, regardless of
    // recipient. Amount is fixed at 100.

    func send(req: Request) async throws -> Response {
        struct Body: Content {
            let friendshipID: UUID
        }
        let body = try req.content.decode(Body.self)
        let accountID = try req.account.requireID()

        guard let friendship = try await Friendship.find(body.friendshipID, on: req.db) else {
            throw Abort(.notFound, reason: "Friendship not found.")
        }
        guard friendship.involves(accountID),
              let friendID = friendship.otherAccountID(besides: accountID)
        else {
            throw Abort(.forbidden, reason: "You are not part of this friendship.")
        }
        guard friendship.status == FriendshipStatus.accepted.rawValue else {
            throw Abort(.conflict, reason: "You can only send gifts to accepted friends.")
        }

        // One gift per sender per UTC calendar day.
        let alreadySent = try await CoinGift.query(on: req.db)
            .filter(\.$from.$id == accountID)
            .filter(\.$createdAt >= Self.startOfTodayUTC())
            .first()
        guard alreadySent == nil else {
            throw Abort(.conflict, reason: "You've already sent today's gift.")
        }

        let gift = CoinGift(
            fromAccountID: accountID,
            toAccountID: friendID,
            amount: Self.giftAmount
        )
        try await gift.save(on: req.db)

        let response = Response(status: .created)
        try response.content.encode(GiftCreatedResponse(giftID: try gift.requireID()))
        return response
    }

    // MARK: - GET /gifts/pending
    //
    // Unclaimed gifts addressed to me, newest first.

    func pending(req: Request) async throws -> [PendingGiftDTO] {
        let accountID = try req.account.requireID()

        let rows = try await CoinGift.query(on: req.db)
            .filter(\.$to.$id == accountID)
            .filter(\.$claimedAt == nil)
            .sort(\.$createdAt, .descending)
            .all()
        guard !rows.isEmpty else { return [] }

        let senders = try await accountsKeyedByID(rows.map { $0.$from.id }, on: req.db)

        return rows.compactMap { row in
            guard let id = row.id else { return nil }
            return PendingGiftDTO(
                giftID: id,
                fromDisplayName: displayNameOrFallback(senders[row.$from.id]?.displayName),
                amount: row.amount,
                createdAt: row.createdAt ?? Date()
            )
        }
    }

    // MARK: - POST /gifts/:giftID/claim
    //
    // Idempotent: claiming an already-claimed gift is also 204. Only the
    // recipient may claim.

    func claim(req: Request) async throws -> HTTPStatus {
        guard let giftID = req.parameters.get("giftID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid gift id.")
        }
        let accountID = try req.account.requireID()

        guard let gift = try await CoinGift.find(giftID, on: req.db) else {
            throw Abort(.notFound, reason: "Gift not found.")
        }
        guard gift.$to.id == accountID else {
            throw Abort(.forbidden, reason: "This gift isn't addressed to you.")
        }

        if gift.claimedAt == nil {
            gift.claimedAt = Date()
            try await gift.save(on: req.db)
        }
        return .noContent
    }

    // MARK: - Helpers

    /// Midnight today in UTC — the boundary for "one gift per calendar day".
    static func startOfTodayUTC(now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: now)
    }

    /// Batch-load accounts and key them by id.
    private func accountsKeyedByID(_ ids: [UUID], on db: any Database) async throws -> [UUID: Account] {
        guard !ids.isEmpty else { return [:] }
        let accounts = try await Account.query(on: db)
            .filter(\.$id ~~ Array(Set(ids)))
            .all()
        var byID: [UUID: Account] = [:]
        for account in accounts {
            if let id = account.id { byID[id] = account }
        }
        return byID
    }

    private func displayNameOrFallback(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player" : trimmed
    }
}

// MARK: - Response DTOs

struct GiftCreatedResponse: Content {
    let giftID: UUID
}

struct PendingGiftDTO: Content {
    let giftID: UUID
    let fromDisplayName: String
    let amount: Int
    let createdAt: Date
}
