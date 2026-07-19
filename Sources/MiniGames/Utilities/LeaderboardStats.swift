import Fluent
import Vapor

// MARK: - LeaderboardStats
//
// Shared aggregation over game_results used by the public leaderboard, the
// personal-rank endpoint, and group leaderboards. Uses the same win convention
// as MeController / FriendsController: an account "played" a row if it was on
// either side; it "won" if it was the questioner and the outcome was "won", or
// the answerer and the outcome was "lost" (the guesser failed).
//
// Streaks: for each account, results are ordered newest-first and the run of
// consecutive same-kind results counted (+N = N straight wins, -N = N straight
// losses, 0 = no games). The scan is capped at the most recent 25 results.

enum LeaderboardStats {

    /// Max results considered when computing a streak.
    static let streakScanCap = 25

    struct AccountLine {
        var played: Int = 0
        var won: Int = 0
        var streak: Int = 0
    }

    /// Aggregate (played, won, streak) per account from game_results.
    /// Pass nil to aggregate over ALL accounts with attributed results;
    /// otherwise only the given ids are considered.
    static func lines(
        for ids: [UUID]?,
        on db: any Database
    ) async throws -> [UUID: AccountLine] {

        // Same two-plain-queries-merged pattern as MeController (relational
        // key-path filters are reliable OUTSIDE a `.group` closure).
        let combined: [GameResult]
        if let ids {
            guard !ids.isEmpty else { return [:] }
            let optionalIDs: [UUID?] = Array(Set(ids))
            async let asAnswerer = GameResult.query(on: db)
                .filter(\.$answererAccount.$id ~~ optionalIDs)
                .all()
            async let asQuestioner = GameResult.query(on: db)
                .filter(\.$questionerAccount.$id ~~ optionalIDs)
                .all()
            combined = try await (asAnswerer + asQuestioner)
        } else {
            async let asAnswerer = GameResult.query(on: db)
                .filter(\.$answererAccount.$id != nil)
                .all()
            async let asQuestioner = GameResult.query(on: db)
                .filter(\.$questionerAccount.$id != nil)
                .all()
            combined = try await (asAnswerer + asQuestioner)
        }

        let idSet = ids.map(Set.init)

        // De-dupe (a row attributed on both sides matches both queries), then
        // bucket each row under every relevant account.
        var seen = Set<UUID>()
        var perAccount: [UUID: [GameResult]] = [:]
        for r in combined {
            guard let rid = r.id, seen.insert(rid).inserted else { continue }
            if let answererID = r.$answererAccount.id,
               idSet?.contains(answererID) ?? true {
                perAccount[answererID, default: []].append(r)
            }
            if let questionerID = r.$questionerAccount.id,
               idSet?.contains(questionerID) ?? true {
                perAccount[questionerID, default: []].append(r)
            }
        }

        var lines: [UUID: AccountLine] = [:]
        for (accountID, rows) in perAccount {
            var line = AccountLine()
            line.played = rows.count
            line.won = rows.filter { $0.countsAsWin(for: accountID) }.count
            line.streak = streak(for: accountID, in: rows)
            lines[accountID] = line
        }
        return lines
    }

    /// Signed streak from the account's rows: consecutive most-recent results
    /// of the same kind, newest first, scan capped at `streakScanCap`.
    private static func streak(for accountID: UUID, in rows: [GameResult]) -> Int {
        let newestFirst = rows
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .prefix(streakScanCap)
        guard let first = newestFirst.first else { return 0 }

        let kind = first.countsAsWin(for: accountID)
        var run = 0
        for r in newestFirst {
            guard r.countsAsWin(for: accountID) == kind else { break }
            run += 1
        }
        return kind ? run : -run
    }
}

// MARK: - GameResult win helper (shared)

extension GameResult {
    /// Win convention (matches MeController): the questioner wins on "won"
    /// (they guessed it); the answerer "wins" when the guesser failed ("lost").
    func countsAsWin(for accountID: UUID) -> Bool {
        if $questionerAccount.id == accountID { return outcome == "won" }
        if $answererAccount.id == accountID { return outcome == "lost" }
        return false
    }
}
