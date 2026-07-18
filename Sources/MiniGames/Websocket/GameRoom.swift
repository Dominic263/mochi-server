import Foundation

final class GameRoom {
    var state: GameState
    var answererSend: ((String) -> Void)?
    var questionerSend: ((String) -> Void)?

    /// Which side is played by a server-side AI (nil for human-vs-human rooms).
    /// Lets lifecycle code reason about "is a human still here" — the AI's send
    /// closure never goes nil on its own, which used to keep AI rooms alive forever.
    var aiRole: PlayerRole?

    /// Idempotency guard: set once when the terminal GameResult row is enqueued
    /// so extra messages arriving in the won/lost phase can't write duplicates.
    /// Reset when a rematch puts the room back into play.
    var resultWritten = false

    /// Generation markers for each side's live socket. A reconnect replaces the
    /// send closure AND the id; the OLD socket's close handler then no-ops
    /// instead of nulling out the fresh connection.
    var answererConnectionID: UUID?
    var questionerConnectionID: UUID?

    init(state: GameState) {
        self.state = state
    }

    func sendToAnswerer(_ event: GameEventEnvelope) {
        answererSend?(event.toJSON())
    }

    func sendToQuestioner(_ event: GameEventEnvelope) {
        questionerSend?(event.toJSON())
    }

    func broadcast(_ event: GameEventEnvelope) {
        let json = event.toJSON()
        answererSend?(json)
        questionerSend?(json)
    }

    /// Dispatches events from an EngineResult in the correct order:
    /// 1. Individual snapshots (toAnswerer / toQuestioner) arrive first so the
    ///    client has up-to-date state (e.g. questionsRemaining) before processing
    ///    the semantic event (toBoth — answerGiven, questionAsked, etc.)
    func dispatch(_ result: EngineResult) {
        // Step 1: send role-specific events first (usually stateSnapshots)
        if let event = result.toAnswerer {
            sendToAnswerer(event)
        }
        if let event = result.toQuestioner {
            sendToQuestioner(event)
        }
        // Step 2: send the shared semantic event after snapshots are delivered
        if let event = result.toBoth {
            broadcast(event)
        }
    }

    var bothConnected: Bool {
        answererSend != nil && questionerSend != nil
    }
}
