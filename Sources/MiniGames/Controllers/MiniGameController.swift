import Vapor
import Fluent
import Logging

// MARK: - AI game rate limiting
//
// Every AI game burns 20–40 OpenAI calls, and create-vs-ai used to be
// completely unmetered — any client could farm unbounded spend on our API key.
// In-memory per-player daily cap; resets at local midnight or on restart
// (a restart granting a fresh allowance is acceptable).

actor AIGameRateLimiter {
    static let shared = AIGameRateLimiter()

    private var dayStart = Date()
    private var counts: [String: Int] = [:]

    /// The client enforces 10/day in its UI; the server allows headroom above
    /// that but still bounds a hostile client.
    private let dailyLimit = 20

    func allowGame(playerID: String) -> Bool {
        if !Calendar.current.isDate(Date(), inSameDayAs: dayStart) {
            counts = [:]
            dayStart = Date()
        }
        let used = counts[playerID, default: 0]
        guard used < dailyLimit else { return false }
        counts[playerID] = used + 1
        return true
    }
}

// MARK: - Request field validation

private func validatedPlayerID(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 64 else {
        throw Abort(.badRequest, reason: "Invalid player id.")
    }
    return trimmed
}

private func sanitizedDisplayName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let clipped = String(trimmed.prefix(30))
    return clipped.isEmpty ? "Player" : clipped
}

private func normalizedRoomCode(_ raw: String) throws -> String {
    let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !code.isEmpty, code.count <= 16 else {
        throw Abort(.badRequest, reason: "Invalid room code.")
    }
    return code
}

struct MiniGameController: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let game = routes.grouped("game")
        game.post("create",       use: createGame)
        game.post("join",         use: joinGame)
        game.post("create-vs-ai", use: createGameVsAI)
        game.post("reconnect",    use: reconnect)
        game.post("suggestions",  use: suggestions)
    }

    // MARK: - POST /game/suggestions
    // AI-generated question ideas for the QUESTIONER, based on the live game's
    // actual Q&A history. Capped per room so the button can't farm GPT calls.

    func suggestions(req: Request) async throws -> SuggestionsResponse {
        struct Body: Content {
            let roomCode: String
            let playerID: String
        }
        let body     = try req.content.decode(Body.self)
        let playerID = try validatedPlayerID(body.playerID)
        let roomCode = try normalizedRoomCode(body.roomCode)

        guard let state = WebSocketManager.shared.currentState(for: roomCode) else {
            throw Abort(.notFound, reason: "Game not found.")
        }
        guard state.questionerID == playerID else {
            throw Abort(.forbidden, reason: "Only the questioner can request suggestions.")
        }
        guard await SuggestionRateLimiter.shared.allow(roomCode: roomCode) else {
            throw Abort(.tooManyRequests, reason: "No more AI suggestions this game.")
        }
        guard let openAIKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "Suggestions unavailable.")
        }

        let history = state.questionsAsked
            .map { q -> String in
                let label = q.question.lowercased().hasPrefix("guess:") ? "GUESS" : "Q\(q.questionNumber)"
                return "\(label): \(q.question) → \(q.answer ?? "pending")"
            }
            .joined(separator: "\n")

        let openAI = OpenAIClient(apiKey: openAIKey, client: req.application.client)
        let raw = try await openAI.chat(
            system: """
                You help a 20 Questions player choose their next yes/no question.
                Given the game so far, propose exactly 3 SHORT yes/no questions that
                each narrow the space efficiently, are consistent with every answer
                so far, and repeat nothing already asked. One per line, no numbering,
                no commentary — just the three questions.
                """,
            messages: [OpenAIClient.Message(role: "user", content: """
                Questions remaining: \(state.questionsRemaining)
                Game so far:
                \(history.isEmpty ? "(no questions yet)" : history)
                """)],
            maxTokens: 90,
            temperature: 0.8
        )

        let questions = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•1234567890. ")) }
            .filter { !$0.isEmpty }
            .prefix(3)

        return SuggestionsResponse(questions: Array(questions))
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

        // Cross-check the live, in-memory room. Two ways it can be missing:
        //   • the cleanup timer reaped it (both players gone > grace window) —
        //     genuinely expired, reject;
        //   • the SERVER restarted — the DB row is fine and the game is
        //     recoverable, so rehydrate the room from the persisted state.
        // AI games can't be rehydrated (the AI actor's in-memory reasoning is
        // gone), so those stay expired.
        if !WebSocketManager.shared.isRoomReconnectable(roomCode: state.roomCode) {
            let wasReaped = WebSocketManager.shared.wasRecentlyCleaned(roomCode: state.roomCode)
            if session.gameType == "twenty_questions_ai" || wasReaped {
                req.logger.info("⌛ Reconnect denied for \(state.roomCode): expired (aiGame=\(session.gameType == "twenty_questions_ai"), reaped=\(wasReaped)).")
                throw Abort(.notFound, reason: "This game has expired.")
            }
            WebSocketManager.shared.ensureRoom(state: state)
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
        let playerID    = try validatedPlayerID(body.playerID)
        let displayName = sanitizedDisplayName(body.displayName)

        let roomCode = try await uniqueRoomCode(db: req.db)
        let state    = GameState(roomCode: roomCode, answererID: playerID, answererDisplayName: displayName)

        let session = GameSession(
            roomCode: roomCode,
            gameType: "twenty_questions",
            answererID: playerID,
            state: state
        )
        try await session.save(on: req.db)

        WebSocketManager.shared.createRoom(state: state)

        let token = UUID().uuidString
        PendingConnections.shared.add(
            token: token,
            connection: PendingConnection(
                playerID: playerID,
                roomCode: roomCode,
                role: .answerer,
                displayName: displayName
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
        let playerID    = try validatedPlayerID(body.playerID)
        let displayName = sanitizedDisplayName(body.displayName)
        let roomCode    = try normalizedRoomCode(body.roomCode)

        guard let session = try await GameSession.query(on: req.db)
            .filter(\.$roomCode == roomCode)
            .filter(\.$phase    == GamePhase.lobby.rawValue)
            .first()
        else {
            throw Abort(.notFound, reason: "Room not found or game already in progress.")
        }

        guard session.answererID != playerID else {
            throw Abort(.conflict, reason: "You created this room — share the code with your opponent.")
        }

        let token = UUID().uuidString
        PendingConnections.shared.add(
            token: token,
            connection: PendingConnection(
                playerID: playerID,
                roomCode: roomCode,
                role: .questioner,
                displayName: displayName
            )
        )

        return JoinGameResponse(token: token)
    }

    // MARK: - POST /game/create-vs-ai

    func createGameVsAI(req: Request) async throws -> CreateGameResponse {
        struct Body: Content {
            let playerID: String
            let displayName: String
            let aiRole: String
            // Optional so shipped clients (which don't send it) keep working.
            let difficulty: String?
        }
        let body = try req.content.decode(Body.self)
        let playerID    = try validatedPlayerID(body.playerID)
        let displayName = sanitizedDisplayName(body.displayName)
        let difficulty  = body.difficulty.flatMap(AIDifficulty.init(rawValue:)) ?? .medium

        guard await AIGameRateLimiter.shared.allowGame(playerID: playerID) else {
            throw Abort(.tooManyRequests, reason: "Daily AI game limit reached. Try again tomorrow.")
        }

        let aiRole: PlayerRole    = body.aiRole == "answerer" ? .answerer : .questioner
        let humanRole: PlayerRole = aiRole == .answerer ? .questioner : .answerer

        let roomCode = try await uniqueRoomCode(db: req.db)
        let aiID     = UUID().uuidString
        let aiName   = AIPlayer.randomName()

        let answererID:   String = aiRole == .answerer ? aiID          : playerID
        let answererName: String = aiRole == .answerer ? aiName        : displayName

        let state = GameState(
            roomCode: roomCode,
            answererID: answererID,
            answererDisplayName: answererName
        )

        let session = GameSession(
            roomCode: roomCode,
            // Distinct type so reconnect knows this room can't be rehydrated
            // after a restart (the AI actor's reasoning state dies with the
            // process).
            gameType: "twenty_questions_ai",
            answererID: answererID,
            state: state
        )
        try await session.save(on: req.db)

        WebSocketManager.shared.createRoom(state: state)

        let humanToken = UUID().uuidString
        PendingConnections.shared.add(
            token: humanToken,
            connection: PendingConnection(
                playerID: playerID,
                roomCode: roomCode,
                role: humanRole,
                displayName: displayName
            )
        )

        guard let openAIKey = Environment.get("OPENAI_API_KEY") else {
            throw Abort(.internalServerError, reason: "OpenAI key not configured on server.")
        }
        // Use the application-scoped HTTP client: the AI actor outlives this
        // request by minutes, and a request-scoped client is not safe to hold
        // past the request's lifetime.
        let app    = req.application
        let openAI = OpenAIClient(apiKey: openAIKey, client: app.client)
        let ai     = AIPlayer(
            playerID: aiID,
            roomCode: roomCode,
            role: aiRole,
            openAI: openAI,
            difficulty: difficulty
        )

        Task { await ai.start(on: app) }

        req.logger.info("🤖 AI game created: \(roomCode), AI role: \(aiRole.rawValue), difficulty: \(difficulty.rawValue)")
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

        // Connection generation id — lets the close handler for THIS socket
        // no-op if a reconnect has already replaced it (stale-close race).
        var connectionID: UUID?

        switch role {

        case .answerer:
            connectionID = WebSocketManager.shared.connectAnswerer(roomCode: roomCode, send: sendClosure)
            if let state = WebSocketManager.shared.currentState(for: roomCode) {
                sendClosure(GameEventEnvelope.stateSnapshot(state.answererView()).toJSON())
            }

        case .questioner:
            connectionID = WebSocketManager.shared.connectQuestioner(
                roomCode: roomCode,
                playerID: playerID,
                displayName: displayName,
                send: sendClosure
            )
            if connectionID != nil {

                if isReconnect {
                    // Reconnecting questioner: the answerer never left, so DON'T
                    // re-fire opponentJoined. Send the snapshot IMMEDIATELY — no
                    // 0.5s delay — so the resuming client restores state without
                    // sitting in a connecting limbo.
                    if let freshState = WebSocketManager.shared.currentState(for: roomCode) {
                        sendClosure(GameEventEnvelope.stateSnapshot(freshState.questionerView()).toJSON())
                    }
                } else {
                    // First-time join: the 0.5s delay gives the answerer's side a
                    // beat before the snapshot, and we notify the answerer that
                    // the opponent has arrived. (Task.sleep, NOT the main dispatch
                    // queue — that queue is never serviced under Vapor/NIO.)
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
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

        // Immutable copy for the Sendable close handler below.
        let socketConnectionID = connectionID

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

                    // Idempotency: every message observed in the won/lost phase
                    // used to write ANOTHER GameResult row, inflating stats.
                    // claimResultWrite returns true exactly once per finished game.
                    guard WebSocketManager.shared.claimResultWrite(roomCode: roomCode) else { return }

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

            if let state = WebSocketManager.shared.disconnect(roomCode: roomCode, role: role, connectionID: socketConnectionID) {
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

    static func writeGameResult(
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

struct SuggestionsResponse: Content {
    let questions: [String]
}

/// Caps AI-suggestion GPT calls per room (the client offers a couple of free
/// regenerations, then gates behind a rewarded ad — this is the hard backstop).
actor SuggestionRateLimiter {
    static let shared = SuggestionRateLimiter()
    private var counts: [String: Int] = [:]
    private let perGameLimit = 8

    func allow(roomCode: String) -> Bool {
        let used = counts[roomCode, default: 0]
        guard used < perGameLimit else { return false }
        counts[roomCode] = used + 1
        if counts.count > 2000 { counts = [:] }   // bounded memory
        return true
    }
}

struct JoinGameResponse: Content {
    let token: String
}

struct ReconnectResponse: Content {
    let roomCode: String
    let token: String
    let role: String       // "answerer" or "questioner"
    let phase: String      // Current game phase
}
