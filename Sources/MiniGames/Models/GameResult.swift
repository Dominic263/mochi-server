import Fluent
import Vapor

// MARK: - GameResult
// Immutable record written once when a game ends (won or lost).
// Never updated — used for stats, history, and leaderboards.
// Kept separate from GameSession so session rows can be reset
// without losing historical records.
//
// S3: now also carries nullable account references. The raw answererID /
// questionerID strings are kept (they're the in-game client UUIDs and the AI's
// ephemeral id), and alongside them we stamp the resolved ACCOUNT for each human
// side. The AI side — and any pre-account rows — leave the account null.

final class GameResult: Model, Content, @unchecked Sendable {
    static let schema = "game_results"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "room_code")
    var roomCode: String

    @Field(key: "game_type")
    var gameType: String

    @Field(key: "answerer_id")
    var answererID: String

    @Field(key: "questioner_id")
    var questionerID: String

    // Resolved accounts (nullable — AI side / pre-account rows are null).
    @OptionalParent(key: "answerer_account_id")
    var answererAccount: Account?

    @OptionalParent(key: "questioner_account_id")
    var questionerAccount: Account?

    @Field(key: "outcome")
    var outcome: String           // "won" or "lost"

    @Field(key: "secret")
    var secret: String            // what the thing was

    @Field(key: "questions_used")
    var questionsUsed: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        roomCode: String,
        gameType: String,
        answererID: String,
        questionerID: String,
        outcome: String,
        secret: String,
        questionsUsed: Int,
        answererAccountID: UUID? = nil,
        questionerAccountID: UUID? = nil
    ) {
        self.roomCode      = roomCode
        self.gameType      = gameType
        self.answererID    = answererID
        self.questionerID  = questionerID
        self.outcome       = outcome
        self.secret        = secret
        self.questionsUsed = questionsUsed
        self.$answererAccount.id   = answererAccountID
        self.$questionerAccount.id = questionerAccountID
    }
}
