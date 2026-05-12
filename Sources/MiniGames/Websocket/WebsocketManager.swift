import Foundation
import Vapor

final class WebSocketManager: @unchecked Sendable {

    static let shared = WebSocketManager()
    private init() {}

    private var rooms: [String: GameRoom] = [:]
    private var aiPlayers: [String: AIPlayer] = [:]
    private var cleanupTimers: [String: DispatchWorkItem] = [:]  // NEW: Track scheduled cleanups
    private let queue = DispatchQueue(label: "com.minigames.wsmanager", attributes: .concurrent)
    
    // Configuration
    private let roomCleanupTimeout: TimeInterval = 600  // 10 minutes (adjustable)

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
        queue.async(flags: .barrier) {
            self.aiPlayers.removeValue(forKey: roomCode)
        }
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
            self.cancelCleanupTimer(for: code)
        }
    }

    // MARK: - Connection

    func connectAnswerer(roomCode: String, send: @escaping @Sendable (String) -> Void) {
        queue.async(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return }
            room.answererSend = send
            
            // If answerer reconnects, cancel any pending cleanup
            self.cancelCleanupTimer(for: roomCode)
            print("✅ [\(roomCode)] Answerer connected/reconnected")
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
            
            // If questioner reconnects, cancel any pending cleanup
            self.cancelCleanupTimer(for: roomCode)
            print("✅ [\(roomCode)] Questioner connected/reconnected")
            
            return room
        }
    }

    // MARK: - Graceful Disconnect (NEW - supports reconnection)

    func disconnect(roomCode: String, role: PlayerRole) -> GameState? {
        queue.sync(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return nil }
            
            // Mark connection as inactive but DON'T remove the room yet
            switch role {
            case .answerer:
                room.answererSend = nil
                print("🔌 [\(roomCode)] Answerer disconnected (room kept alive)")
            case .questioner:
                room.questionerSend = nil
                print("🔌 [\(roomCode)] Questioner disconnected (room kept alive)")
            }
            
            let bothDisconnected = room.answererSend == nil && room.questionerSend == nil
            let gameEnded = room.state.phase == .won || room.state.phase == .lost
            
            if bothDisconnected && gameEnded {
                // Game is over and both players gone → immediate cleanup
                print("🗑️ [\(roomCode)] Both players gone + game ended → immediate cleanup")
                self.rooms.removeValue(forKey: roomCode)
                self.aiPlayers.removeValue(forKey: roomCode)
                self.cancelCleanupTimer(for: roomCode)
            } else if bothDisconnected {
                // Game is still active but both disconnected → schedule cleanup
                print("⏰ [\(roomCode)] Both disconnected but game active → scheduling cleanup in \(Int(self.roomCleanupTimeout))s")
                self.scheduleCleanup(for: roomCode)
            } else {
                // One player still connected → cancel any pending cleanup
                self.cancelCleanupTimer(for: roomCode)
            }
            
            return room.state
        }
    }

    // MARK: - Cleanup Timer Management (NEW)

    private func scheduleCleanup(for roomCode: String) {
        // Cancel any existing timer first
        cancelCleanupTimer(for: roomCode)
        
        let workItem = DispatchWorkItem { [weak self] in
            self?.queue.async(flags: .barrier) {
                // Only cleanup if still disconnected
                guard let room = self?.rooms[roomCode],
                      room.answererSend == nil,
                      room.questionerSend == nil else {
                    print("⏰ [\(roomCode)] Cleanup cancelled - player reconnected")
                    return
                }
                
                print("🗑️ [\(roomCode)] Cleanup timeout reached → removing room")
                self?.rooms.removeValue(forKey: roomCode)
                self?.aiPlayers.removeValue(forKey: roomCode)
                self?.cleanupTimers.removeValue(forKey: roomCode)
            }
        }
        
        cleanupTimers[roomCode] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + roomCleanupTimeout, execute: workItem)
    }

    private func cancelCleanupTimer(for roomCode: String) {
        cleanupTimers[roomCode]?.cancel()
        cleanupTimers.removeValue(forKey: roomCode)
    }

    // MARK: - Close both connections and clean up everything

    func closeBothConnections(roomCode: String) {
        queue.async(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return }
            room.answererSend = nil
            room.questionerSend = nil
            self.rooms.removeValue(forKey: roomCode)
            self.aiPlayers.removeValue(forKey: roomCode)
            self.cancelCleanupTimer(for: roomCode)
            print("🗑️ [\(roomCode)] Manual cleanup - both connections closed")
        }
    }

    // MARK: - Message handling

    func handle(raw: String, playerID: String, roomCode: String, role: PlayerRole) {
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
                self.aiPlayers.removeValue(forKey: roomCode)
                self.cancelCleanupTimer(for: roomCode)
                print("🗑️ [\(roomCode)] Game dismissed by player")
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
                // Send typing indicators before processing
                switch action.type {
                case .askQuestion:
                    if let room = self.rooms[roomCode] {
                        room.sendToAnswerer(.typingIndicator())
                    }
                case .answerQuestion:
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
                    self.aiPlayers.removeValue(forKey: roomCode)
                    self.cancelCleanupTimer(for: roomCode)
                    print("🗑️ [\(roomCode)] Game engine closed connections")
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
    
    // MARK: - Reconnection Support (NEW)
    
    /// Check if a room exists and is reconnectable (lobby or playing phase)
    func isRoomReconnectable(roomCode: String) -> Bool {
        queue.sync {
            guard let room = self.rooms[roomCode] else { return false }
            return room.state.phase == .lobby || room.state.phase == .playing
        }
    }
    
    /// Get count of active (connected) players in a room
    func activePlayerCount(for roomCode: String) -> Int {
        queue.sync {
            guard let room = self.rooms[roomCode] else { return 0 }
            var count = 0
            if room.answererSend != nil { count += 1 }
            if room.questionerSend != nil { count += 1 }
            return count
        }
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
    
    // MARK: - Diagnostics (useful for debugging)
    
    func roomCount() -> Int {
        queue.sync { rooms.count }
    }
    
    func activeRoomCodes() -> [String] {
        queue.sync { Array(rooms.keys) }
    }
    
    func roomInfo(for roomCode: String) -> String? {
        queue.sync {
            guard let room = rooms[roomCode] else { return nil }
            let answererConnected = room.answererSend != nil ? "✓" : "✗"
            let questionerConnected = room.questionerSend != nil ? "✓" : "✗"
            let hasCleanupTimer = cleanupTimers[roomCode] != nil ? "⏰" : ""
            return "[\(roomCode)] Phase: \(room.state.phase.rawValue), Answerer: \(answererConnected), Questioner: \(questionerConnected) \(hasCleanupTimer)"
        }
    }
}
