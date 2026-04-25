import Foundation
import Vapor

final class WebSocketManager: @unchecked Sendable {

    static let shared = WebSocketManager()
    private init() {}

    private var rooms: [String: GameRoom] = [:]
    private var aiPlayers: [String: AIPlayer] = [:]
    private let queue = DispatchQueue(label: "com.minigames.wsmanager", attributes: .concurrent)

    // MARK: - AI Player registration

    func registerAI(_ ai: AIPlayer, roomCode: String) {
        queue.async(flags: .barrier) { self.aiPlayers[roomCode] = ai }
    }

    func routeToAI(playerID: String, roomCode: String, json: String) {
        queue.async {
            guard let ai = self.aiPlayers[roomCode] else { return }
            Task { await ai.receiveEvent(json) }
        }
    }

    func removeAI(roomCode: String) {
        queue.async(flags: .barrier) { self.aiPlayers.removeValue(forKey: roomCode) }
    }

    // MARK: - Room lifecycle

    func createRoom(state: GameState) {
        queue.async(flags: .barrier) {
            self.rooms[state.roomCode] = GameRoom(state: state)
        }
    }

    func removeRoom(code: String) {
        queue.async(flags: .barrier) {
            _ = self.rooms.removeValue(forKey: code)
        }
    }

    // MARK: - Connection

    func connectAnswerer(roomCode: String, send: @escaping @Sendable (String) -> Void) {
        queue.async(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return }
            room.answererSend = send
        }
    }

    func connectQuestioner(
        roomCode: String,
        playerID: String,
        displayName: String,
        send: @escaping @Sendable (String) -> Void
    ) -> GameRoom? {
        queue.sync(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return nil }
            room.state.questionerID = playerID
            room.state.questionerDisplayName = displayName
            room.questionerSend = send
            return room
        }
    }

    // MARK: - Disconnect

    func disconnect(roomCode: String, role: PlayerRole) -> GameState? {
        queue.sync(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return nil }
            switch role {
            case .answerer:   room.answererSend = nil
            case .questioner: room.questionerSend = nil
            }
            return room.state
        }
    }

    // MARK: - Close both connections

    func closeBothConnections(roomCode: String) {
        queue.async(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return }
            room.answererSend = nil
            room.questionerSend = nil
            self.rooms.removeValue(forKey: roomCode)
        }
    }

    // MARK: - Message handling

    func handle(raw: String, playerID: String, roomCode: String, role: PlayerRole) {
        // Run on barrier so reads and writes are safe
        // Use async to avoid blocking the NIO event loop thread
        queue.async(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return }

            if raw.contains("\"dismissGame\"") {
                let opponentLeft = GameEventEnvelope.opponentLeft()
                switch role {
                case .answerer:   room.sendToQuestioner(opponentLeft)
                case .questioner: room.sendToAnswerer(opponentLeft)
                }
                room.answererSend = nil
                room.questionerSend = nil
                self.rooms.removeValue(forKey: roomCode)
                return
            }

            guard
                let data = raw.data(using: .utf8),
                let action = try? JSONDecoder().decode(GameActionEnvelope.self, from: data)
            else {
                let error = GameEventEnvelope.error("Invalid message format")
                switch role {
                case .answerer:   room.sendToAnswerer(error)
                case .questioner: room.sendToQuestioner(error)
                }
                return
            }

            do {
                // Broadcast typing indicator to the waiting player before processing
                // so they see dots while the response is being prepared
                switch action.type {
                case .askQuestion:
                    // Answerer will see dots while questioner's question is processed
                    if let room = self.rooms[roomCode] {
                        room.sendToAnswerer(.typingIndicator())
                    }
                case .answerQuestion:
                    // Questioner will see dots while answerer's response is processed
                    if let room = self.rooms[roomCode] {
                        room.sendToQuestioner(.typingIndicator())
                    }
                default:
                    break
                }

                let result = try GameEngine.process(
                    action: action,
                    playerID: playerID,
                    state: room.state
                )
                room.state = result.state
                print("🎮 [\(roomCode)] engine processed \(action.type.rawValue) → phase: \(result.state.phase.rawValue)")
                room.dispatch(result)

                if result.closeConnections {
                    room.answererSend = nil
                    room.questionerSend = nil
                    self.rooms.removeValue(forKey: roomCode)
                }
            } catch {
                print("❌ [\(roomCode)] engine error for \(action.type.rawValue): \(error)")
                let errorEvent = GameEventEnvelope.error(error.localizedDescription)
                switch role {
                case .answerer:   room.sendToAnswerer(errorEvent)
                case .questioner: room.sendToQuestioner(errorEvent)
                }
            }
        }
    }

    // MARK: - State access

    func currentState(for roomCode: String) -> GameState? {
        queue.sync { self.rooms[roomCode]?.state }
    }

    // MARK: - Direct broadcast

    func sendToAnswerer(in roomCode: String, event: GameEventEnvelope) {
        queue.async { self.rooms[roomCode]?.sendToAnswerer(event) }
    }

    func sendToQuestioner(in roomCode: String, event: GameEventEnvelope) {
        queue.async { self.rooms[roomCode]?.sendToQuestioner(event) }
    }

    func broadcast(to roomCode: String, event: GameEventEnvelope) {
        queue.async { self.rooms[roomCode]?.broadcast(event) }
    }
}
