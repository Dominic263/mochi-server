import Vapor

// Context passed to every marketing page so base.leaf can highlight the active
// nav link. No email signup for Mochi (the app is live) — the hero CTA is the
// App Store button, so we don't need Clarity's success/error/subscribed flags.
struct PageContext: Content {
    var activePage: String
}

func routes(_ app: Application) throws {
    let controller = MiniGameController()
    try app.register(collection: controller)

    // MARK: - Marketing site (Leaf-rendered, no auth)
    // Served at the root domain; the game API lives on the api. subdomain but
    // shares this same Vapor app. Plain closures — no controller needed.
    app.get { req async throws -> View in
        try await req.view.render("index", PageContext(activePage: "home"))
    }
    app.get("privacy") { req async throws -> View in
        try await req.view.render("privacy", PageContext(activePage: "privacy"))
    }
    app.get("terms") { req async throws -> View in
        try await req.view.render("terms", PageContext(activePage: "terms"))
    }

    // S1/S2 — account / identity endpoints (bootstrap, apple-link).
    try app.register(collection: AccountController())

    // S3 — authenticated read endpoints (GET /me/stats, /me/history).
    try app.register(collection: MeController())

    // WebSocket route registered outside any auth middleware.
    // WS upgrade requests cannot carry Authorization headers —
    // identity is established via the one-time token in the query string.
    app.webSocket("game", "ws") { req, ws in
        controller.handleWebSocket(req: req, ws: ws)
    }

    app.get("health") { _ in ["status": "ok"] }
}
