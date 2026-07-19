import Fluent
import FluentPostgresDriver
import JWT
import Leaf
import Vapor

public func configure(_ app: Application) async throws {

    // MARK: - Postgres
    // On Coolify, DATABASE_URL is injected automatically from the linked Postgres service.
    // Locally, fall back to individual env vars (no TLS — local Postgres doesn't need it).
    if let databaseURL = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
    } else {
        app.databases.use(
            DatabaseConfigurationFactory.postgres(configuration: .init(
                hostname: Environment.get("DB_HOST") ?? "localhost",
                port:     Environment.get("DB_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
                username: Environment.get("DB_USER") ?? "vapor",
                password: Environment.get("DB_PASS") ?? "vapor",
                database: Environment.get("DB_NAME") ?? "minigames",
                tls: .disable
            )),
            as: .psql
        )
    }

    // MARK: - Sign in with Apple (S2)
    // Setting the expected application identifier (your app's bundle ID) means
    // `req.jwt.apple.verify(...)` will fetch & cache Apple's public keys (JWKS),
    // verify the identity-token signature, and reject any token whose audience
    // isn't this bundle ID. Override via env in case the bundle ID changes.
    app.jwt.apple.applicationIdentifier =
        Environment.get("APPLE_APP_BUNDLE_ID") ?? "com.relentlessforgellc.mochi"

    // MARK: - Migrations
    app.migrations.add(CreateGameSession())
    app.migrations.add(CreateGameResult())
    app.migrations.add(CreateAccount())              // S1 — accounts + devices
    app.migrations.add(AddAccountsToGameResult())    // S3 — account-stamped results
    app.migrations.add(AddFriendCodeToAccount())     // Friends — shareable friend codes
    app.migrations.add(CreateFriendship())           // Friends — friendships table
    app.migrations.add(CreateFriendChallenge())      // Friends — challenge pointers
    app.migrations.add(CreateFriendGroup())          // Groups — private leaderboard groups
    app.migrations.add(CreateFriendGroupMember())    // Groups — memberships
    app.migrations.add(CreateCoinGift())             // Gifts — daily coin gift ledger
    try await app.autoMigrate()

    // MARK: - Leaf (server-side HTML templating for the marketing site)
    // Renders the landing page + legal pages from Resources/Views/*.leaf.
    app.views.use(.leaf)

    // MARK: - Static files (Public/)
    // Serves CSS, images, favicon, and app-ads.txt straight from /Public at the
    // domain root. FileMiddleware must run before routing so /app-ads.txt and
    // /styles.css resolve to files. (Registered first so it takes precedence for
    // matching paths; dynamic routes still handle everything else.)
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // MARK: - Clock-sweep persistence
    // The WebSocketManager's timer sweep (match/turn clocks) mutates room state
    // outside any request. This hook flushes those mutations to Postgres and,
    // on a timeout-driven game end, writes the immutable GameResult exactly
    // once (claimResultWrite guards against the ws.onText path double-writing).
    let sweepDB = app.db
    let sweepLogger = app.logger
    WebSocketManager.shared.persistState = { roomCode, state in
        Task {
            do {
                if let session = try await GameSession.query(on: sweepDB)
                    .filter(\.$roomCode == roomCode)
                    .first() {
                    session.sync(from: state)
                    try await session.save(on: sweepDB)
                }
            } catch {
                sweepLogger.error("⏱ Failed to persist swept state for \(roomCode): \(error)")
            }

            guard state.phase == .won || state.phase == .lost,
                  let questionerID = state.questionerID,
                  let secret = state.secret,
                  WebSocketManager.shared.claimResultWrite(roomCode: roomCode)
            else { return }

            await MiniGameController.writeGameResult(
                db: sweepDB,
                logger: sweepLogger,
                roomCode: roomCode,
                answererID: state.answererID,
                questionerID: questionerID,
                outcome: state.phase == .won ? "won" : "lost",
                secret: secret,
                questionsUsed: 20 - state.questionsRemaining
            )
        }
    }

    // MARK: - Routes
    try routes(app)
}
