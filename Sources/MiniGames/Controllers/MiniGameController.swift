import Vapor
import Fluent
import Logging

struct MiniGameController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let game = routes.grouped("game")
        game.post("create",       use: createGame)
        game.post("join",         use: joinGame)
        game.post("create-vs-ai", use: createGameVsAI)
        game.post("reconnect",    use: reconnect)
    }

    // MARK: - POST /game/reconnect
    // Finds any active game where this player is a participant and returns
    // a fresh token + current game state. Handles both multiplayer and AI games.
    //
    // CRITICAL: the authoritative live game lives in WebSocketManager's in-memory
    // rooms, NOT the DB. The DB row can say "playing" even after the in-memory
    // room has been reaped by the cleanup timer. We therefore cross-check the
    // live room and treat "DB active but no live room" as an expired game (404),
    // so the client gets an honest signal to fall back instead of connecting a
    // socket to a room that no longer exists.

    func reconnect(req: Request) async throws -> ReconnectResponse {
        struct Body: Content {
            let playerID: String
        }
        let body = try req.content.decode(Body.self)

        // Find any active session where this player is answerer or questioner
        let activeSessions = try await GameSession.query(on: req.db)
            .group(.or) { group in
                group.filter(\.$answererID == body.playerID)
                group.filter(\.$questionerID == body.playerID)
            }
            .filter(\.$phase ~~ ["lobby", "playing"]) // Only active games
            .sort(\.$updatedAt, .descending) // Most recent first
            .all()

        guard let session = activeSessions.first else {
            throw Abort(.notFound, reason: "No active game found for this player.")
        }

        guard let state = session.loadState() else {
            throw Abort(.internalServerError, reason: "Could not load game state.")
        }

        // Cross-check the live, in-memory room. If the cleanup timer already
        // reaped it, the game is gone even though the DB row lingers.
        guard WebSocketManager.shared.isRoomReconnectable(roomCode: state.roomCode) else {
            req.logger.info("⌛ Reconnect denied for \(state.roomCode): no live room (expired).")
            throw Abort(.notFound, reason: "This game has expired.")
        }

        // Determine player's role
        let role: PlayerRole = body.playerID == state.answererID ? .answerer : .questioner
        let displayName = role == .answerer
            ? state.answererDisplayName
            : state.questionerDisplayName ?? "Player"

        // Generate fresh token for reconnection — flagged as a reconnect.
        let token = UUID().uuidString
        PendingConnections.shared.add(
            token: token,
            connection: PendingConnection(
                playerID: body.playerID,
                roomCode: state.roomCode,
                role: role,
                displayName: displayName,
                isReconnect: true
            )
        )

        req.logger.info("🔄 Player \(body.playerID) reconnecting to \(state.roomCode) as \(role.rawValue)")

        return ReconnectResponse(
            roomCode: state.roomCode,
            token: token,
            role: role.rawValue,
            phase: state.phase.rawValue
        )
    }

    // MARK: - Unique room code helper

    private func uniqueRoomCode(db: any Database) async throws -> String {
        for attempt in 0..<10 {
            let code = attempt < 5
                ? RoomCodeGenerator.generate()
                : RoomCodeGenerator.generate() + "-\(Int.random(in: 10...99))"
            let existing = try await GameSession.query(on: db)
                .filter(\.$roomCode == code)
                .count()
            if existing == 0 { return code }
        }
        return String(UUID().uuidString.prefix(8)).uppercased()
    }

    // MARK: - POST /game/create

    func createGame(req: Request) async throws -> CreateGameResponse {
        struct Body: Content {
            let playerID: String
            let displayName: String
        }
        let body = try req.content.decode(Body.self)

        let roomCode = try await uniqueRoomCode(db: req.db)
        let state    = GameState(roomCode: roomCode, answererID: body.playerID, answererDisplayName: body.displayName)

        let session = GameSession(
            roomCode: roomCode,
            gameType: "twenty_questions",
            answererID: body.playerID,
            state: state
        )
        try await session.save(on: req.db)

        WebSocketManager.shared.createRoom(state: state)

        let token = UUID().uuidString
        PendingConnections.shared.add(
            token: token,
            connection: PendingConnection(
                playerID: body.playerID,
                roomCode: roomCode,
                role: .answerer,
                displayName: body.displayName
            )
        )

        return CreateGameResponse(roomCode: roomCode, token: token)
    }

    // MARK: - POST /game/join

    func joinGame(req: Request) async throws -> JoinGameResponse {
        struct Body: Content {
            let playerID: String
            let roomCode: String
            let displayName: String
        }
        let body = try req.content.decode(Body.self)

        guard let session = try await GameSession.query(on: req.db)
            .filter(\.$roomCode == body.roomCode)
            .filter(\.$phase    == GamePhase.lobby.rawValue)
            .first()
        else {
            throw Abort(.notFound, reason: "Room not found or game already in progress.")
        }

        guard session.answererID != body.playerID else {
            throw Abort(.conflict, reason: "You created this room — share the code with your opponent.")
        }

        let token = UUID().uuidString
        PendingConnections.shared.add(
            token: token,
            connection: PendingConnection(
                playerID: body.playerID,
                roomCode: body.roomCode,
                role: .questioner,
                displayName: body.displayName
            )
        )

        return JoinGameResponse(token: token)
    }

    // MARK: - POST /game/rematch

    func rematch(req: Request) async throws -> RematchResponse {
        struct Body: Content {
            let playerID: String
            let roomCode: String
            let displayName: String
        }
        let body = try req.content.decode(Body.self)

        guard let state = WebSocketManager.shared.currentState(for: body.roomCode) else {
            throw Abort(.notFound, reason: "Room not found.")
        }

        let role: PlayerRole = body.playerID == state.answererID ? .answerer : .questioner

        let token = UUID().uuidString
        PendingConnections.shared.add(
            token: token,
            connection: PendingConnection(
                playerID: body.playerID,
                roomCode: body.roomCode,
                role: role,
                displayName: body.displayName
            )
        )

        return RematchResponse(token: token, roomCode: body.roomCode)
    }

    // MARK: - POST /game/create-vs-ai

    func createGameVsAI(req: Request) async throws -> CreateGameResponse {
        struct Body: Content {
            let playerID: String
            let displayName: String
            let aiRole: String
        }
        let body = try req.content.decode(Body.self)

        let aiRole: PlayerRole    = body.aiRole == "answerer" ? .answerer : .questioner
        let humanRole: PlayerRole = aiRole == .answerer ? .questioner : .answerer

        let roomCode = try await uniqueRoomCode(db: req.db)
        let aiID     = UUID().uuidString
        let aiName   = AIPlayer.randomName()

        let answererID:   String = aiRole == .answerer ? aiID          : body.playerID
        let answererName: String = aiRole == .answerer ? aiName        : body.displayName

        let state = GameState(
            roomCode: roomCode,
            answererID: answererID,
            answererDisplayName: answererName
        )

        let session = GameSession(
            roomCode: roomCode,
            gameType: "twenty_questions",
            answererID: answererID,
            state: state
        )
        try await session.save(on: req.db)

        WebSocketManager.shared.createRoom(state: state)

        let humanToken = UUID().uuidString
        PendingConnections.shared.add(
            token: humanToken,
            connection: PendingConnection(
                playerID: body.playerID,
                roomCode: roomCode,
                role: humanRole,
                displayName: body.displayName
            )
        )

        guard let openAIKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "OpenAI key not configured on server.")
        }
        let openAI = OpenAIClient(apiKey: openAIKey, client: req.client)
        let ai     = AIPlayer(playerID: aiID, roomCode: roomCode, role: aiRole, openAI: openAI)

        let app = req.application
        Task { await ai.start(on: app) }

        req.logger.info("🤖 AI game created: \(roomCode), AI role: \(aiRole.rawValue)")
        return CreateGameResponse(roomCode: roomCode, token: humanToken)
    }

    // MARK: - WebSocket handler

    func handleWebSocket(req: Request, ws: WebSocket) {
        guard
            let token = req.query[String.self, at: "token"],
            let conn  = PendingConnections.shared.consume(token: token)
        else {
            ws.send(GameEventEnvelope.error("Invalid or expired token").toJSON(), promise: nil)
            ws.close(promise: nil)
            return
        }

        let playerID    = conn.playerID
        let roomCode    = conn.roomCode
        let role        = conn.role
        let displayName = conn.displayName
        let isReconnect = conn.isReconnect
        let db          = req.db
        let logger      = req.logger

        let sendClosure: @Sendable (String) -> Void = { message in
            ws.send(message, promise: nil)
        }

        switch role {

        case .answerer:
            WebSocketManager.shared.connectAnswerer(roomCode: roomCode, send: sendClosure)
            if let state = WebSocketManager.shared.currentState(for: roomCode) {
                sendClosure(GameEventEnvelope.stateSnapshot(state.answererView()).toJSON())
            }

        case .questioner:
            if WebSocketManager.shared.connectQuestioner(
                roomCode: roomCode,
                playerID: playerID,
                displayName: displayName,
                send: sendClosure
            ) != nil {

                if isReconnect {
                    // Reconnecting questioner: the answerer never left, so DON'T
                    // re-fire opponentJoined. Send the snapshot IMMEDIATELY — no
                    // 0.5s delay — so the resuming client restores state without
                    // sitting in a connecting limbo.
                    if let freshState = WebSocketManager.shared.currentState(for: roomCode) {
                        sendClosure(GameEventEnvelope.stateSnapshot(freshState.questionerView()).toJSON())
                    }
                } else {
                    // First-time join: original behavior. The 0.5s delay gives the
                    // answerer's side a beat before the snapshot, and we notify the
                    // answerer that the opponent has arrived.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let freshState = WebSocketManager.shared.currentState(for: roomCode) {
                            sendClosure(GameEventEnvelope.stateSnapshot(freshState.questionerView()).toJSON())
                        }
                    }

                    WebSocketManager.shared.sendToAnswerer(
                        in: roomCode,
                        event: .opponentJoined(displayName: displayName)
                    )
                }

                // Persist questionerID on both first-join and reconnect. Cheap and
                // keeps the DB row authoritative for the next reconnect lookup.
                db.query(GameSession.self)
                    .filter(\.$roomCode == roomCode)
                    .first()
                    .whenSuccess { session in
                        guard let session = session else { return }
                        session.questionerID = playerID
                        session.save(on: db).whenFailure { err in
                            logger.error("Failed to persist questionerID: \(err)")
                        }
                    }
            } else {
                sendClosure(GameEventEnvelope.error("Room not found.").toJSON())
                ws.close(promise: nil)
                return
            }
        }

        ws.onText { _, text in
            logger.info("📨 [\(roomCode)] received: \(text.prefix(100))")
            WebSocketManager.shared.handle(
                raw: text,
                playerID: playerID,
                roomCode: roomCode,
                role: role
            )

            guard let state = WebSocketManager.shared.currentState(for: roomCode) else { return }

            db.query(GameSession.self)
                .filter(\.$roomCode == roomCode)
                .first()
                .whenSuccess { session in
                    guard let session = session else { return }
                    session.sync(from: state)
                    session.save(on: db).whenFailure { err in
                        logger.error("Failed to flush state: \(err)")
                    }

                    guard
                        state.phase == .won || state.phase == .lost,
                        let questionerID = state.questionerID,
                        let secret       = state.secret
                    else { return }

                    // Write the immutable result, resolving each human side to its
                    // account (S3). Done in an async helper so the device→account
                    // lookups read cleanly; the AI side resolves to nil.
                    let outcome = state.phase == .won ? "won" : "lost"
                    Task {
                        await Self.writeGameResult(
                            db: db,
                            logger: logger,
                            roomCode: roomCode,
                            answererID: state.answererID,
                            questionerID: questionerID,
                            outcome: outcome,
                            secret: secret,
                            questionsUsed: 20 - state.questionsRemaining
                        )
                    }
                }
        }

        ws.onClose.whenComplete { _ in
            // IMPORTANT: We do NOT remove the AI player here.
            //
            // A socket close is indistinguishable from a recoverable disconnect
            // (background / sleep / network blip). The human may reconnect within
            // the room's grace window. The AI player is event-driven and holds no
            // socket of its own — it simply waits idle for the next routed event —
            // so leaving it registered costs nothing and lets the resumed game
            // continue. Killing it here was the bug that froze AI games on resume:
            // after removeAI, the reconnected human's questions/answers had no AI
            // to route to and were silently dropped.
            //
            // The AI is still cleaned up by every TERMINAL path:
            //   • game over → AIPlayer's own loop calls removeAI on gameWon/gameLost
            //   • explicit quit → handle(raw:) "dismissGame" calls removeAI
            //   • grace window expires → scheduleCleanup removes aiPlayers[roomCode]
            //   • closeBothConnections → calls removeAI
            // so this is not a leak; it only stops a RECOVERABLE drop from killing it.

            if let state = WebSocketManager.shared.disconnect(roomCode: roomCode, role: role) {
                db.query(GameSession.self)
                    .filter(\.$roomCode == roomCode)
                    .first()
                    .whenSuccess { session in
                        guard let session = session else { return }
                        session.sync(from: state)
                        session.save(on: db).whenFailure { err in
                            logger.error("Failed to flush state on disconnect: \(err)")
                        }
                    }

                // NOTE: We intentionally do NOT broadcast opponentLeft here.
                // A socket close from ws.onClose is indistinguishable from a
                // mere background / sleep / network blip — the player may
                // reconnect within the room's grace window. Punishing the
                // OTHER player for that is bad gameplay, so a silent drop stays
                // invisible to them; they remain in their normal waiting state.
                //
                // An EXPLICIT quit is handled separately in handle(raw:) via the
                // "dismissGame" message, which still broadcasts opponentLeft
                // before the socket closes. That path is unaffected.
                //
                // The room is kept alive by disconnect(...) and reaped only if
                // nobody reconnects before the cleanup timer fires.
            }
            logger.info("🎮 [\(roomCode)] \(playerID) disconnected (room kept alive, opponent not notified)")
        }
    }
    // MARK: - Game result writing (S3)
    //
    // Resolves each side's in-game client UUID to an Account via the device map,
    // then writes the immutable GameResult stamped with whatever accounts were
    // found. The AI side (an ephemeral UUID with no device row) resolves to nil,
    // as do any human ids whose device hasn't been bootstrapped — both are fine,
    // the columns are nullable.

    private static func writeGameResult(
        db: any Database,
        logger: Logger,
        roomCode: String,
        answererID: String,
        questionerID: String,
        outcome: String,
        secret: String,
        questionsUsed: Int
    ) async {
        do {
            let answererAccountID   = try await accountID(for: answererID, on: db)
            let questionerAccountID = try await accountID(for: questionerID, on: db)

            let result = GameResult(
                roomCode:            roomCode,
                gameType:            "twenty_questions",
                answererID:          answererID,
                questionerID:        questionerID,
                outcome:             outcome,
                secret:              secret,
                questionsUsed:       questionsUsed,
                answererAccountID:   answererAccountID,
                questionerAccountID: questionerAccountID
            )
            try await result.save(on: db)
        } catch {
            logger.error("Failed to save game result: \(error)")
        }
    }

    /// Look up the account id that owns a given in-game client UUID, via the
    /// device map. Returns nil if there's no device (e.g. the AI side).
    private static func accountID(for clientPlayerID: String, on db: any Database) async throws -> UUID? {
        try await Device.query(on: db)
            .filter(\.$clientPlayerID == clientPlayerID)
            .first()?
            .$account.id
    }

}

    // MARK: - Response types

struct CreateGameResponse: Content {
    let roomCode: String
    let token: String
}

struct JoinGameResponse: Content {
    let token: String
}

struct RematchResponse: Content {
    let token: String
    let roomCode: String
}

struct ReconnectResponse: Content {
    let roomCode: String
    let token: String
    let role: String       // "answerer" or "questioner"
    let phase: String      // Current game phase
}
