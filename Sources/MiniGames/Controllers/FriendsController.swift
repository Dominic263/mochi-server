import Vapor
import Fluent

// MARK: - FriendsController
//
// Friends + challenges + public leaderboard. All /friends routes sit behind
// AccountAuthMiddleware (so `req.account` is available); /leaderboard is public.
//
//   GET    /friends                              — my code + friends + incoming/outgoing requests
//   POST   /friends/request                      — send a request by friend code
//   POST   /friends/respond                      — accept/decline a request (addressee only)
//   DELETE /friends/:friendshipID                — unfriend (either side)
//   POST   /friends/challenge                    — record a challenge pointing at an existing lobby room
//   GET    /friends/challenges                   — pending challenges addressed to me (stale ones pruned)
//   POST   /friends/challenges/:challengeID/accept — accept; client then joins via POST /game/join
//   GET    /leaderboard                          — public top-50 by wins (no auth)
//
// Win convention matches MeController: an account "played" a game_results row
// if it was either side; it "won" if it was the questioner and the outcome was
// "won", or the answerer and the outcome was "lost" (the guesser failed).

struct FriendsController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let friends = routes
            .grouped("friends")
            .grouped(AccountAuthMiddleware())
        friends.get(use: index)
        friends.post("request",  use: sendRequest)
        friends.post("respond",  use: respond)
        friends.delete(":friendshipID", use: unfriend)
        friends.post("challenge",  use: createChallenge)
        friends.get("challenges",  use: pendingChallenges)
        friends.post("challenges", ":challengeID", "accept", use: acceptChallenge)

        // Public — deliberately OUTSIDE the auth group.
        routes.get("leaderboard", use: leaderboard)
    }

    // MARK: - GET /friends

    func index(req: Request) async throws -> FriendsResponse {
        let account = req.account
        let accountID = try account.requireID()

        // Lazily backfill this account's friend code.
        let myCode = try await Self.ensureFriendCode(for: account, on: req.db)

        let rows = try await friendshipsInvolving(accountID, on: req.db)

        // Batch-load the account on the OTHER side of every row.
        let otherIDs = rows.compactMap { $0.otherAccountID(besides: accountID) }
        let accountsByID = try await accountsKeyedByID(otherIDs, on: req.db)

        var friends:  [FriendDTO] = []
        var incoming: [FriendRequestDTO] = []
        var outgoing: [FriendRequestDTO] = []

        let acceptedOtherIDs = rows
            .filter { $0.status == FriendshipStatus.accepted.rawValue }
            .compactMap { $0.otherAccountID(besides: accountID) }
        let stats = try await gameStats(for: acceptedOtherIDs, on: req.db)

        for row in rows {
            guard let friendshipID = row.id,
                  let otherID = row.otherAccountID(besides: accountID)
            else { continue }
            let other = accountsByID[otherID]
            let displayName = displayNameOrFallback(other?.displayName)

            if row.status == FriendshipStatus.accepted.rawValue {
                let s = stats[otherID] ?? (played: 0, won: 0)
                friends.append(FriendDTO(
                    friendshipID: friendshipID,
                    accountID: otherID,
                    displayName: displayName,
                    gamesWon: s.won,
                    gamesPlayed: s.played
                ))
            } else {
                let dto = FriendRequestDTO(
                    friendshipID: friendshipID,
                    displayName: displayName,
                    friendCode: other?.friendCode ?? "",
                    createdAt: row.createdAt ?? Date()
                )
                if row.$addressee.id == accountID {
                    incoming.append(dto)
                } else {
                    outgoing.append(dto)
                }
            }
        }

        return FriendsResponse(
            friendCode: myCode,
            friends: friends,
            incoming: incoming,
            outgoing: outgoing
        )
    }

    // MARK: - POST /friends/request
    //
    // Body: { "friendCode": "K7PM3X" }

    func sendRequest(req: Request) async throws -> FriendRequestDTO {
        struct Body: Content {
            let friendCode: String
        }
        let body = try req.content.decode(Body.self)
        let accountID = try req.account.requireID()

        let code = body.friendCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !code.isEmpty else {
            throw Abort(.badRequest, reason: "friendCode is required.")
        }

        guard let target = try await Account.query(on: req.db)
            .filter(\.$friendCode == code)
            .first()
        else {
            throw Abort(.notFound, reason: "No player with that friend code.")
        }
        let targetID = try target.requireID()

        guard targetID != accountID else {
            throw Abort(.badRequest, reason: "You can't add yourself.")
        }

        // Reject if a friendship (any status) already exists in EITHER direction.
        if try await friendshipBetween(accountID, targetID, on: req.db) != nil {
            throw Abort(.conflict, reason: "A friendship or pending request already exists.")
        }

        let friendship = Friendship(requesterID: accountID, addresseeID: targetID)
        try await friendship.save(on: req.db)

        return FriendRequestDTO(
            friendshipID: try friendship.requireID(),
            displayName: displayNameOrFallback(target.displayName),
            friendCode: code,
            createdAt: friendship.createdAt ?? Date()
        )
    }

    // MARK: - POST /friends/respond
    //
    // Body: { "friendshipID": "<uuid>", "accept": true }
    // Only the ADDRESSEE may respond. Decline deletes the row.

    func respond(req: Request) async throws -> RespondResponse {
        struct Body: Content {
            let friendshipID: UUID
            let accept: Bool
        }
        let body = try req.content.decode(Body.self)
        let accountID = try req.account.requireID()

        guard let friendship = try await Friendship.find(body.friendshipID, on: req.db) else {
            throw Abort(.notFound, reason: "Friend request not found.")
        }
        guard friendship.$addressee.id == accountID else {
            throw Abort(.forbidden, reason: "Only the recipient can respond to a friend request.")
        }
        guard friendship.status == FriendshipStatus.pending.rawValue else {
            throw Abort(.conflict, reason: "This request has already been accepted.")
        }

        if body.accept {
            friendship.status = FriendshipStatus.accepted.rawValue
            try await friendship.save(on: req.db)
            return RespondResponse(status: "accepted")
        } else {
            try await friendship.delete(on: req.db)
            return RespondResponse(status: "declined")
        }
    }

    // MARK: - DELETE /friends/:friendshipID
    //
    // Either side may unfriend; the row is deleted outright.

    func unfriend(req: Request) async throws -> HTTPStatus {
        guard let friendshipID = req.parameters.get("friendshipID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid friendship id.")
        }
        let accountID = try req.account.requireID()

        guard let friendship = try await Friendship.find(friendshipID, on: req.db) else {
            throw Abort(.notFound, reason: "Friendship not found.")
        }
        guard friendship.involves(accountID) else {
            throw Abort(.forbidden, reason: "You are not part of this friendship.")
        }

        try await friendship.delete(on: req.db)
        return .noContent
    }

    // MARK: - POST /friends/challenge
    //
    // Body: { "friendshipID": "<uuid>", "roomCode": "WOLF-42" }
    //
    // The client has ALREADY created the game room (POST /game/create — the
    // challenger is the answerer). This just records a challenge row so the
    // friend can discover the room. Any previous pending challenge between the
    // same pair (either direction) is superseded (deleted) first.

    func createChallenge(req: Request) async throws -> Response {
        struct Body: Content {
            let friendshipID: UUID
            let roomCode: String
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
            throw Abort(.conflict, reason: "You can only challenge accepted friends.")
        }

        let roomCode = body.roomCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard let session = try await GameSession.query(on: req.db)
            .filter(\.$roomCode == roomCode)
            .sort(\.$createdAt, .descending)
            .first()
        else {
            throw Abort(.notFound, reason: "No game room with that code.")
        }
        guard session.phase == GamePhase.lobby.rawValue else {
            throw Abort(.conflict, reason: "That room is no longer open.")
        }

        // Supersede any previous pending challenge between this pair (both directions).
        try await deletePendingChallenges(between: accountID, and: friendID, on: req.db)

        let challenge = FriendChallenge(
            fromAccountID: accountID,
            toAccountID: friendID,
            roomCode: roomCode
        )
        try await challenge.save(on: req.db)

        let response = Response(status: .created)
        try response.content.encode(ChallengeCreatedResponse(challengeID: try challenge.requireID()))
        return response
    }

    // MARK: - GET /friends/challenges
    //
    // Pending challenges addressed to me, newest first. Challenges whose game
    // session has left the lobby are stale — they're deleted lazily here.

    func pendingChallenges(req: Request) async throws -> [ChallengeDTO] {
        let accountID = try req.account.requireID()

        let rows = try await FriendChallenge.query(on: req.db)
            .filter(\.$to.$id == accountID)
            .filter(\.$status == FriendChallengeStatus.pending.rawValue)
            .sort(\.$createdAt, .descending)
            .all()
        guard !rows.isEmpty else { return [] }

        // Which of those room codes are still sitting in the lobby?
        let codes = Array(Set(rows.map(\.roomCode)))
        let sessions = try await GameSession.query(on: req.db)
            .filter(\.$roomCode ~~ codes)
            .all()
        let lobbyCodes = Set(
            sessions
                .filter { $0.phase == GamePhase.lobby.rawValue }
                .map(\.roomCode)
        )

        var live: [FriendChallenge] = []
        for row in rows {
            if lobbyCodes.contains(row.roomCode) {
                live.append(row)
            } else {
                try await row.delete(on: req.db)   // lazy stale cleanup
            }
        }

        let senders = try await accountsKeyedByID(live.map { $0.$from.id }, on: req.db)

        return live.compactMap { row in
            guard let id = row.id else { return nil }
            return ChallengeDTO(
                challengeID: id,
                fromDisplayName: displayNameOrFallback(senders[row.$from.id]?.displayName),
                roomCode: row.roomCode,
                createdAt: row.createdAt ?? Date()
            )
        }
    }

    // MARK: - POST /friends/challenges/:challengeID/accept
    //
    // Marks the challenge accepted and hands back the room code; the client
    // then joins through the normal POST /game/join flow.

    func acceptChallenge(req: Request) async throws -> AcceptChallengeResponse {
        guard let challengeID = req.parameters.get("challengeID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid challenge id.")
        }
        let accountID = try req.account.requireID()

        guard let challenge = try await FriendChallenge.find(challengeID, on: req.db) else {
            throw Abort(.notFound, reason: "Challenge not found.")
        }
        guard challenge.$to.id == accountID else {
            throw Abort(.forbidden, reason: "This challenge isn't addressed to you.")
        }

        // Idempotent: accepting twice just returns the room code again.
        if challenge.status != FriendChallengeStatus.accepted.rawValue {
            challenge.status = FriendChallengeStatus.accepted.rawValue
            try await challenge.save(on: req.db)
        }

        return AcceptChallengeResponse(roomCode: challenge.roomCode)
    }

    // MARK: - GET /leaderboard  (public — no auth)
    //
    // Top 50 accounts by wins, computed live from game_results. Only accounts
    // with at least one attributed result appear; missing display names fall
    // back to "Player".

    func leaderboard(req: Request) async throws -> [LeaderboardEntry] {
        // All results attributed to ANY account on either side.
        async let asAnswerer = GameResult.query(on: req.db)
            .filter(\.$answererAccount.$id != nil)
            .all()
        async let asQuestioner = GameResult.query(on: req.db)
            .filter(\.$questionerAccount.$id != nil)
            .all()
        let combined = try await (asAnswerer + asQuestioner)

        // De-dupe (a row with both sides attributed matches both queries),
        // then aggregate per account.
        var seen = Set<UUID>()
        var stats: [UUID: (played: Int, won: Int)] = [:]
        for r in combined {
            guard let rid = r.id, seen.insert(rid).inserted else { continue }
            if let answererID = r.$answererAccount.id {
                stats[answererID, default: (0, 0)].played += 1
                if r.outcome == "lost" { stats[answererID, default: (0, 0)].won += 1 }
            }
            if let questionerID = r.$questionerAccount.id {
                stats[questionerID, default: (0, 0)].played += 1
                if r.outcome == "won" { stats[questionerID, default: (0, 0)].won += 1 }
            }
        }
        guard !stats.isEmpty else { return [] }

        let accountsByID = try await accountsKeyedByID(Array(stats.keys), on: req.db)

        return stats
            .map { (id, s) in
                LeaderboardEntry(
                    displayName: displayNameOrFallback(accountsByID[id]?.displayName),
                    wins: s.won,
                    gamesPlayed: s.played
                )
            }
            .sorted {
                if $0.wins != $1.wins { return $0.wins > $1.wins }
                if $0.gamesPlayed != $1.gamesPlayed { return $0.gamesPlayed > $1.gamesPlayed }
                return $0.displayName < $1.displayName
            }
            .prefix(50)
            .map { $0 }
    }

    // MARK: - Friend-code backfill

    /// Returns the account's friend code, generating + saving a unique one if
    /// it doesn't have one yet. Retries on collision (the unique index on
    /// accounts.friend_code is the backstop for concurrent races).
    static func ensureFriendCode(for account: Account, on db: any Database) async throws -> String {
        if let code = account.friendCode, !code.isEmpty { return code }

        for _ in 0..<8 {
            let candidate = FriendCodeGenerator.generate()
            let clash = try await Account.query(on: db)
                .filter(\.$friendCode == candidate)
                .first()
            guard clash == nil else { continue }

            account.friendCode = candidate
            do {
                try await account.save(on: db)
                return candidate
            } catch {
                // Lost a race on the unique index — clear and try another code.
                account.friendCode = nil
                continue
            }
        }
        throw Abort(.internalServerError, reason: "Could not generate a unique friend code.")
    }

    // MARK: - Shared queries

    /// All friendship rows where the account is either side. Two plain queries
    /// merged — same pattern as MeController (relational key-path filters are
    /// reliable OUTSIDE a `.group` closure).
    private func friendshipsInvolving(_ accountID: UUID, on db: any Database) async throws -> [Friendship] {
        async let asRequester = Friendship.query(on: db)
            .filter(\.$requester.$id == accountID)
            .all()
        async let asAddressee = Friendship.query(on: db)
            .filter(\.$addressee.$id == accountID)
            .all()
        let combined = try await (asRequester + asAddressee)

        var seen = Set<UUID>()
        return combined.filter { row in
            guard let id = row.id else { return true }
            return seen.insert(id).inserted
        }
    }

    /// The friendship row (any status) between two accounts, in either direction.
    private func friendshipBetween(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Friendship? {
        if let forward = try await Friendship.query(on: db)
            .filter(\.$requester.$id == a)
            .filter(\.$addressee.$id == b)
            .first()
        {
            return forward
        }
        return try await Friendship.query(on: db)
            .filter(\.$requester.$id == b)
            .filter(\.$addressee.$id == a)
            .first()
    }

    /// Delete all pending challenges between two accounts, in either direction.
    private func deletePendingChallenges(between a: UUID, and b: UUID, on db: any Database) async throws {
        try await FriendChallenge.query(on: db)
            .filter(\.$from.$id == a)
            .filter(\.$to.$id == b)
            .filter(\.$status == FriendChallengeStatus.pending.rawValue)
            .delete()
        try await FriendChallenge.query(on: db)
            .filter(\.$from.$id == b)
            .filter(\.$to.$id == a)
            .filter(\.$status == FriendChallengeStatus.pending.rawValue)
            .delete()
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

    /// Per-account (played, won) aggregated from game_results for the given
    /// accounts, using the MeController win convention.
    private func gameStats(for ids: [UUID], on db: any Database) async throws -> [UUID: (played: Int, won: Int)] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        let optionalIDs: [UUID?] = Array(idSet)

        async let asAnswerer = GameResult.query(on: db)
            .filter(\.$answererAccount.$id ~~ optionalIDs)
            .all()
        async let asQuestioner = GameResult.query(on: db)
            .filter(\.$questionerAccount.$id ~~ optionalIDs)
            .all()
        let combined = try await (asAnswerer + asQuestioner)

        var seen = Set<UUID>()
        var stats: [UUID: (played: Int, won: Int)] = [:]
        for r in combined {
            guard let rid = r.id, seen.insert(rid).inserted else { continue }
            if let answererID = r.$answererAccount.id, idSet.contains(answererID) {
                stats[answererID, default: (0, 0)].played += 1
                if r.outcome == "lost" { stats[answererID, default: (0, 0)].won += 1 }
            }
            if let questionerID = r.$questionerAccount.id, idSet.contains(questionerID) {
                stats[questionerID, default: (0, 0)].played += 1
                if r.outcome == "won" { stats[questionerID, default: (0, 0)].won += 1 }
            }
        }
        return stats
    }

    private func displayNameOrFallback(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player" : trimmed
    }
}

// MARK: - Response DTOs

struct FriendsResponse: Content {
    let friendCode: String
    let friends: [FriendDTO]
    let incoming: [FriendRequestDTO]
    let outgoing: [FriendRequestDTO]
}

struct FriendDTO: Content {
    let friendshipID: UUID
    let accountID: UUID
    let displayName: String
    let gamesWon: Int
    let gamesPlayed: Int
}

struct FriendRequestDTO: Content {
    let friendshipID: UUID
    let displayName: String
    let friendCode: String
    let createdAt: Date
}

struct RespondResponse: Content {
    let status: String        // "accepted" or "declined"
}

struct ChallengeCreatedResponse: Content {
    let challengeID: UUID
}

struct ChallengeDTO: Content {
    let challengeID: UUID
    let fromDisplayName: String
    let roomCode: String
    let createdAt: Date
}

struct AcceptChallengeResponse: Content {
    let roomCode: String
}

struct LeaderboardEntry: Content {
    let displayName: String
    let wins: Int
    let gamesPlayed: Int
}
