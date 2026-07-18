import Foundation
import Vapor

final class WebSocketManager: @unchecked Sendable {

    static let shared = WebSocketManager()
    private init() {}

    private var rooms: [String: GameRoom] = [:]
    private var aiPlayers: [String: AIPlayer] = [:]
    // Structured-concurrency cleanup timers. The previous implementation used
    // DispatchQueue.main.asyncAfter, but the main queue is never serviced in a
    // Vapor/NIO process (the main thread is parked in app.execute()) — those
    // work items never fired and rooms leaked forever.
    private var cleanupTimers: [String: Task<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "com.minigames.wsmanager", attributes: .concurrent)

    // Configuration
    private let roomCleanupTimeout: TimeInterval = 600  // 10 minutes (adjustable)

    // MARK: - AI Player registration

    func registerAI(_ ai: AIPlayer, roomCode: String) {
        queue.async(flags: .barrier) {
            self.aiPlayers[roomCode] = ai
            self.rooms[roomCode]?.aiRole = ai.role
        }
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

    /// Connects the answerer's socket. Returns a connection id the caller must
    /// hand back to disconnect() so a stale socket can't tear down a newer one.
    @discardableResult
    func connectAnswerer(roomCode: String, send: @escaping @Sendable (String) -> Void) -> UUID? {
        queue.sync(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return nil }
            let connectionID = UUID()
            room.answererSend = send
            room.answererConnectionID = connectionID

            // If answerer reconnects, cancel any pending cleanup
            self.cancelCleanupTimer(for: roomCode)
            print("✅ [\(roomCode)] Answerer connected/reconnected")
            return connectionID
        }
    }

    func connectQuestioner(
        roomCode: String,
        playerID: String,
        displayName: String,
        send: @escaping @Sendable (String) -> Void
    ) -> UUID? {
        queue.sync(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return nil }
            let connectionID = UUID()
            room.state.questionerID = playerID
            room.state.questionerDisplayName = displayName
            room.questionerSend = send
            room.questionerConnectionID = connectionID

            // If questioner reconnects, cancel any pending cleanup
            self.cancelCleanupTimer(for: roomCode)
            print("✅ [\(roomCode)] Questioner connected/reconnected")
            return connectionID
        }
    }

    // MARK: - Graceful Disconnect (supports reconnection)

    /// True while at least one HUMAN socket is attached. The AI's send closure
    /// is a routing shim, not a socket — it must never count as "connected".
    private func humanConnected(in room: GameRoom) -> Bool {
        switch room.aiRole {
        case .answerer:   return room.questionerSend != nil
        case .questioner: return room.answererSend != nil
        case nil:         return room.answererSend != nil || room.questionerSend != nil
        }
    }

    func disconnect(roomCode: String, role: PlayerRole, connectionID: UUID? = nil) -> GameState? {
        queue.sync(flags: .barrier) {
            guard let room = self.rooms[roomCode] else { return nil }

            // Stale-socket guard: if a reconnect already replaced this side's
            // connection, the old socket's close event must not null the new one.
            switch role {
            case .answerer:
                if let connectionID, room.answererConnectionID != connectionID {
                    print("🔌 [\(roomCode)] Stale answerer socket closed — newer connection active, ignoring")
                    return room.state
                }
                room.answererSend = nil
                room.answererConnectionID = nil
                print("🔌 [\(roomCode)] Answerer disconnected (room kept alive)")
            case .questioner:
                if let connectionID, room.questionerConnectionID != connectionID {
                    print("🔌 [\(roomCode)] Stale questioner socket closed — newer connection active, ignoring")
                    return room.state
                }
                room.questionerSend = nil
                room.questionerConnectionID = nil
                print("🔌 [\(roomCode)] Questioner disconnected (room kept alive)")
            }

            // For AI rooms the AI side never disconnects on its own, so room
            // lifetime is driven purely by whether a human is still attached.
            let roomEmpty = !self.humanConnected(in: room)
            let gameEnded = room.state.phase == .won || room.state.phase == .lost

            if roomEmpty && gameEnded {
                // Game is over and every human is gone → immediate cleanup
                print("🗑️ [\(roomCode)] Humans gone + game ended → immediate cleanup")
                self.removeRoomLocked(roomCode)
            } else if roomEmpty {
                // Game still active but nobody human is here → grace window
                print("⏰ [\(roomCode)] No humans connected but game active → scheduling cleanup in \(Int(self.roomCleanupTimeout))s")
                self.scheduleCleanup(for: roomCode)
            } else {
                // A human is still connected → cancel any pending cleanup
                self.cancelCleanupTimer(for: roomCode)
            }

            return room.state
        }
    }

    // MARK: - Cleanup Timer Management

    /// Must be called on the barrier queue.
    private func removeRoomLocked(_ roomCode: String) {
        self.rooms.removeValue(forKey: roomCode)
        self.aiPlayers.removeValue(forKey: roomCode)
        self.cancelCleanupTimer(for: roomCode)
    }

    private func scheduleCleanup(for roomCode: String) {
        // Cancel any existing timer first
        cancelCleanupTimer(for: roomCode)

        let timeout = roomCleanupTimeout
        cleanupTimers[roomCode] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }

            self.queue.async(flags: .barrier) {
                // Only clean up if no human came back during the grace window
                guard let room = self.rooms[roomCode], !self.humanConnected(in: room) else {
                    print("⏰ [\(roomCode)] Cleanup cancelled - player reconnected")
                    self.cleanupTimers.removeValue(forKey: roomCode)
                    return
                }

                print("🗑️ [\(roomCode)] Cleanup timeout reached → removing room")
                self.removeRoomLocked(roomCode)
            }
        }
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

            // Explicit quit — decode-verified (the old raw substring check fired
            // on ANY payload containing the literal "dismissGame").
            if action.type == .dismissGame {
                let opponentLeft = GameEventEnvelope.opponentLeft()
                switch role {
                case .answerer:   room.sendToQuestioner(opponentLeft)
                case .questioner: room.sendToAnswerer(opponentLeft)
                }
                room.answererSend = nil
                room.questionerSend = nil
                self.removeRoomLocked(roomCode)
                print("🗑️ [\(roomCode)] Game dismissed by player")
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
                // A rematch puts the room back into play — the next game's
                // terminal result must be writable again.
                if result.state.phase == .playing || result.state.phase == .lobby {
                    room.resultWritten = false
                }
                print("🎮 [\(roomCode)] engine processed \(action.type.rawValue) → phase: \(result.state.phase.rawValue)")
                room.dispatch(result)

                if result.closeConnections {
                    room.answererSend = nil
                    room.questionerSend = nil
                    self.removeRoomLocked(roomCode)
                    print("🗑️ [\(roomCode)] Game engine closed connections")
                }
            } catch {
                print("❌ [\(roomCode)] engine error for \(action.type.rawValue): \(error)")
                // EngineError's localizedDescription is the useless generic
                // Foundation text — surface the real message instead.
                let message = (error as? EngineError)?.description ?? error.localizedDescription
                let errorEvent = GameEventEnvelope.error(message)
                switch role {
                case .answerer:   room.sendToAnswerer(errorEvent)
                case .questioner: room.sendToQuestioner(errorEvent)
                }
            }
        }
    }

    // MARK: - Terminal result idempotency

    /// Atomically claims the right to persist this room's terminal GameResult.
    /// Returns true exactly once per finished game — extra messages observed in
    /// the won/lost phase (the source of duplicate stat rows) return false.
    func claimResultWrite(roomCode: String) -> Bool {
        queue.sync(flags: .barrier) {
            guard let room = self.rooms[roomCode], !room.resultWritten else { return false }
            room.resultWritten = true
            return true
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
