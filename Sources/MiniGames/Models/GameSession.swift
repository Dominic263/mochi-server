import Fluent
import Vapor

// MARK: - GameSession
// One row per room. Written at room creation, updated on every state
// change and on disconnect. This is the durable record — if the server
// restarts, rooms are rehydrated from here.

final class GameSession: Model, Content, @unchecked Sendable {
    static let schema = "game_sessions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "room_code")
    var roomCode: String

    @Field(key: "game_type")
    var gameType: String          // "twenty_questions" — extensible for future games

    @Field(key: "answerer_id")
    var answererID: String

    @Field(key: "questioner_id")
    var questionerID: String?     // set when questioner joins

    @Field(key: "state_json")
    var stateJSON: String         // full GameState encoded as JSON

    @Field(key: "phase")
    var phase: String             // mirrors GamePhase.rawValue for easy querying

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(roomCode: String, gameType: String, answererID: String, state: GameState) {
        self.roomCode    = roomCode
        self.gameType    = gameType
        self.answererID  = answererID
        self.questionerID = nil
        self.phase       = GamePhase.lobby.rawValue
        self.stateJSON   = state.toJSON()
    }

    // MARK: - Helpers

    /// Decode the stored JSON back into a GameState
    func loadState() -> GameState? {
        guard
            let data  = stateJSON.data(using: .utf8),
            let state = try? JSONDecoder().decode(GameState.self, from: data)
        else { return nil }
        return state
    }

    /// Sync this row from a live GameState (call before every save)
    func sync(from state: GameState) {
        self.questionerID = state.questionerID
        self.phase        = state.phase.rawValue
        self.stateJSON    = state.toJSON()
    }
}
