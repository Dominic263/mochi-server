import Fluent
import FluentPostgresDriver
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

    // MARK: - Migrations
    app.migrations.add(CreateGameSession())
    app.migrations.add(CreateGameResult())
    try await app.autoMigrate()

    
   
    // MARK: - Routes
    try routes(app)
}
