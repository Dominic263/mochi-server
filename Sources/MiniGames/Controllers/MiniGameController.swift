import Vapor
import Fluent

struct MiniGameController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let game = routes.grouped("game")
        game.post("create",       use: createGame)
        game.post("join",         use: joinGame)
        game.post("create-vs-ai", use: createGameVsAI)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let freshState = WebSocketManager.shared.currentState(for: roomCode) {
                        sendClosure(GameEventEnvelope.stateSnapshot(freshState.questionerView()).toJSON())
                    }
                }

                WebSocketManager.shared.sendToAnswerer(
                    in: roomCode,
                    event: .opponentJoined(displayName: displayName)
                )

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

                    let outcome = state.phase == .won ? "won" : "lost"
                    let result  = GameResult(
                        roomCode:      roomCode,
                        gameType:      "twenty_questions",
                        answererID:    state.answererID,
                        questionerID:  questionerID,
                        outcome:       outcome,
                        secret:        secret,
                        questionsUsed: 20 - state.questionsRemaining
                    )
                    result.save(on: db).whenFailure { err in
                        logger.error("Failed to save game result: \(err)")
                    }
                }
        }

        ws.onClose.whenComplete { _ in
            // Always clean up the AI player for this room on any disconnect.
            // This covers the case where a human leaves mid-game without sending
            // dismissGame — the AI task is released and stops consuming resources.
            WebSocketManager.shared.removeAI(roomCode: roomCode)

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

                if state.phase == .lobby || state.phase == .playing {
                    WebSocketManager.shared.broadcast(to: roomCode, event: .opponentLeft())
                }
            }
            logger.info("🎮 [\(roomCode)] \(playerID) disconnected")
        }
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
