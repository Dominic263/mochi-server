import Vapor
import Fluent

// MARK: - PlayersController
//
// Public (authenticated) player profiles — what you see when you tap another
// player on a leaderboard or friends list. Sits behind AccountAuthMiddleware,
// same pattern as /gifts.
//
//   GET /players/:accountID/profile — appearance, progression, and stats
//
// Stats come from the shared LeaderboardStats aggregation, so the numbers
// always agree with /leaderboard and group leaderboards (same win convention:
// the questioner wins on "won", the answerer wins on "lost").

struct PlayersController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let players = routes
            .grouped("players")
            .grouped(AccountAuthMiddleware())
        players.get(":accountID", "profile", use: profile)
    }

    // MARK: - GET /players/:accountID/profile

    func profile(req: Request) async throws -> PlayerProfileResponse {
        guard let accountID = req.parameters.get("accountID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid account id.")
        }

        guard let account = try await Account.find(accountID, on: req.db) else {
            throw Abort(.notFound, reason: "Player not found.")
        }

        let line = try await LeaderboardStats.lines(for: [accountID], on: req.db)[accountID]
            ?? LeaderboardStats.AccountLine()
        let losses = line.played - line.won
        let winRatePercent = line.played > 0
            ? Int((Double(line.won) / Double(line.played) * 100).rounded())
            : 0

        return PlayerProfileResponse(
            accountID: accountID,
            displayName: displayNameOrFallback(account.displayName),
            avatarID: account.avatarID,
            headwear: account.equippedHeadwear,
            eyewear: account.equippedEyewear,
            neckwear: account.equippedNeckwear,
            xp: account.xp ?? 0,
            level: account.level ?? 1,
            gamesPlayed: line.played,
            wins: line.won,
            losses: losses,
            winRatePercent: winRatePercent,
            streak: line.streak,
            memberSince: account.createdAt
        )
    }

    // MARK: - Helpers

    private func displayNameOrFallback(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player" : trimmed
    }
}

// MARK: - Response DTO

struct PlayerProfileResponse: Content {
    let accountID: UUID
    let displayName: String
    let avatarID: String?
    let headwear: String?
    let eyewear: String?
    let neckwear: String?
    let xp: Int
    let level: Int
    let gamesPlayed: Int
    let wins: Int
    let losses: Int
    let winRatePercent: Int   // 0–100, rounded
    let streak: Int           // +N straight wins, -N straight losses
    let memberSince: Date?    // account createdAt
}
