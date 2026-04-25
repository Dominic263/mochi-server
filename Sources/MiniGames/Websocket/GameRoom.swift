import Foundation

final class GameRoom {
    var state: GameState
    var answererSend: ((String) -> Void)?
    var questionerSend: ((String) -> Void)?

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

    func dispatch(_ result: EngineResult) {
        if let event = result.toBoth {
            broadcast(event)
        }
        if let event = result.toAnswerer {
            sendToAnswerer(event)
        }
        if let event = result.toQuestioner {
            sendToQuestioner(event)
        }
    }

    var bothConnected: Bool {
        answererSend != nil && questionerSend != nil
    }
}
