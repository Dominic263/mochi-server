import Vapor
import Fluent

// MARK: - MeController  (S3)
//
// Authenticated read endpoints for the calling account. All routes sit behind
// AccountAuthMiddleware, so `req.account` is always available.
//
//   GET /me/stats     — aggregate stats (games played, won, win rate, words unlocked)
//   GET /me/history   — recent games + the distinct set of words unlocked
//
// "Words unlocked" is DERIVED from game_results (distinct secrets the account
// has played), not stored separately — it can never drift out of sync, and the
// Mochi-journey modal only needs the count + list. A dedicated table can be
// added later if per-word metadata is ever needed.

struct MeController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let me = routes
            .grouped("me")
            .grouped(AccountAuthMiddleware())
        me.get("stats",   use: stats)
        me.get("history", use: history)
    }

    // MARK: - GET /me/stats

    func stats(req: Request) async throws -> StatsResponse {
        let accountID = try req.account.requireID()

        // All results where this account was either side.
        let results = try await resultsForAccount(accountID, on: req.db)

        let gamesPlayed = results.count
        let gamesWon = results.filter { $0.isWinForAccount(accountID) }.count
        let wordsUnlocked = Set(results.map { $0.secret.lowercased() }).count

        let winRate: Double = gamesPlayed > 0
            ? (Double(gamesWon) / Double(gamesPlayed))
            : 0

        return StatsResponse(
            accountID: accountID,
            displayName: req.account.displayName,
            gamesPlayed: gamesPlayed,
            gamesWon: gamesWon,
            winRate: winRate,
            wordsUnlocked: wordsUnlocked
        )
    }

    // MARK: - GET /me/history
    //
    // Response is the original { games, wordsUnlocked } object PLUS the
    // additive `history` array: up to 200 newest results with my role, the
    // outcome from MY perspective, and the opponent's display name resolved
    // via one batched account load ("Mochi AI" when the other side has no
    // account — the AI's ephemeral id never maps to a device). The top-level
    // shape is deliberately unchanged so shipped clients keep decoding.

    func history(req: Request) async throws -> HistoryResponse {
        let accountID = try req.account.requireID()

        let results = try await resultsForAccount(accountID, on: req.db)

        let newestFirst = results
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }

        // Recent games, newest first (legacy shape, untouched).
        let games: [HistoryResponse.Game] = newestFirst
            .map { r in
                HistoryResponse.Game(
                    roomCode: r.roomCode,
                    gameType: r.gameType,
                    outcome: r.outcome,
                    won: r.isWinForAccount(accountID),
                    secret: r.secret,
                    questionsUsed: r.questionsUsed,
                    playedAt: r.createdAt
                )
            }

        // Detailed entries (additive): 200 newest, opponents batch-loaded.
        let recent = Array(newestFirst.prefix(200))
        let opponentIDs = recent.compactMap { r -> UUID? in
            r.$answererAccount.id == accountID
                ? r.$questionerAccount.id
                : r.$answererAccount.id
        }
        let opponents = try await accountsKeyedByID(opponentIDs, on: req.db)

        let entries: [HistoryResponse.Entry] = recent.compactMap { r in
            guard let id = r.id else { return nil }
            let iAmAnswerer = r.$answererAccount.id == accountID
            let opponentAccountID = iAmAnswerer
                ? r.$questionerAccount.id
                : r.$answererAccount.id

            // No account on the other side → it was the AI (or a pre-account
            // row); an account id that no longer resolves → generic fallback.
            let opponentDisplayName: String
            if let opponentAccountID {
                opponentDisplayName = displayNameOrFallback(opponents[opponentAccountID]?.displayName)
            } else {
                opponentDisplayName = "Mochi AI"
            }

            return HistoryResponse.Entry(
                id: id,
                roomCode: r.roomCode,
                myRole: iAmAnswerer ? "answerer" : "questioner",
                // Same win convention as leaderboards (GameResult.countsAsWin).
                outcome: r.countsAsWin(for: accountID) ? "won" : "lost",
                opponentDisplayName: opponentDisplayName,
                secret: r.secret,
                questionsUsed: r.questionsUsed,
                createdAt: r.createdAt ?? Date()
            )
        }

        // Distinct words unlocked (case-insensitive), preserving first-seen order.
        var seen = Set<String>()
        var words: [String] = []
        for r in results.sorted(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }) {
            let key = r.secret.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                words.append(r.secret)
            }
        }

        return HistoryResponse(games: games, wordsUnlocked: words, history: entries)
    }

    // MARK: - Shared query

    /// All results where the account is the answerer OR the questioner.
    /// Two plain queries merged (the relational key-path filter is reliable
    /// OUTSIDE a `.group` closure, where type inference otherwise fails).
    private func resultsForAccount(_ accountID: UUID, on db: any Database) async throws -> [GameResult] {
        async let asAnswerer = GameResult.query(on: db)
            .filter(\.$answererAccount.$id == accountID)
            .all()
        async let asQuestioner = GameResult.query(on: db)
            .filter(\.$questionerAccount.$id == accountID)
            .all()

        // Merge + de-dupe by id (a row could match both sides in edge cases).
        let combined = try await (asAnswerer + asQuestioner)
        var seen = Set<UUID>()
        return combined.filter { r in
            guard let id = r.id else { return true }
            return seen.insert(id).inserted
        }
    }

    /// Batch-load accounts and key them by id (same pattern as FriendsController).
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

// MARK: - GameResult win helper

private extension GameResult {
    /// Did THIS account win this game? The questioner wins on "won" (they guessed
    /// it); the answerer "wins" when the questioner failed ("lost"). For stats we
    /// treat a win as: the questioner-account guessed correctly.
    ///
    /// Mochi is questioner-centric (you're usually trying to guess), so a "win"
    /// for an account means it was the questioner and the outcome was "won".
    func isWinForAccount(_ accountID: UUID) -> Bool {
        if self.$questionerAccount.id == accountID {
            return outcome == "won"
        }
        // Account was the answerer: they "win" when the guesser failed.
        if self.$answererAccount.id == accountID {
            return outcome == "lost"
        }
        return false
    }
}

// MARK: - Response DTOs

struct StatsResponse: Content {
    let accountID: UUID
    let displayName: String?
    let gamesPlayed: Int
    let gamesWon: Int
    let winRate: Double
    let wordsUnlocked: Int
}

struct HistoryResponse: Content {
    struct Game: Content {
        let roomCode: String
        let gameType: String
        let outcome: String      // raw "won"/"lost"
        let won: Bool            // resolved for THIS account
        let secret: String
        let questionsUsed: Int
        let playedAt: Date?
    }

    /// Detailed history row (additive — see the `history` field below).
    struct Entry: Content {
        let id: UUID
        let roomCode: String
        let myRole: String              // "answerer" | "questioner"
        let outcome: String             // "won" | "lost" from MY perspective
        let opponentDisplayName: String // "Mochi AI" when no account on the other side
        let secret: String
        let questionsUsed: Int
        let createdAt: Date
    }

    let games: [Game]
    let wordsUnlocked: [String]
    /// Up to 200 newest results with role/opponent resolved. ADDITIVE field —
    /// old clients decode { games, wordsUnlocked } exactly as before.
    let history: [Entry]
}
