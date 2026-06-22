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

    func history(req: Request) async throws -> HistoryResponse {
        let accountID = try req.account.requireID()

        let results = try await resultsForAccount(accountID, on: req.db)

        // Recent games, newest first.
        let games: [HistoryResponse.Game] = results
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
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

        return HistoryResponse(games: games, wordsUnlocked: words)
    }

    // MARK: - Shared query

    /// All results where the account is the answerer OR the questioner.
    private func resultsForAccount(_ accountID: UUID, on db: any Database) async throws -> [GameResult] {
        try await GameResult.query(on: db)
            .group(.or) { group in
                group.filter(\.$answererAccount.$id == accountID)
                group.filter(\.$questionerAccount.$id == accountID)
            }
            .all()
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
    let games: [Game]
    let wordsUnlocked: [String]
}