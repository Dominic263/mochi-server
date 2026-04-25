import Fluent
import Vapor

// MARK: - GameResult
// Immutable record written once when a game ends (won or lost).
// Never updated — used for stats, history, and leaderboards.
// Kept separate from GameSession so session rows can be reset
// without losing historical records.

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
        questionsUsed: Int
    ) {
        self.roomCode      = roomCode
        self.gameType      = gameType
        self.answererID    = answererID
        self.questionerID  = questionerID
        self.outcome       = outcome
        self.secret        = secret
        self.questionsUsed = questionsUsed
    }
}
