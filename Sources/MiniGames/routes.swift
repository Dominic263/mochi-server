import Vapor

// Context passed to every marketing page so base.leaf can highlight the active
// nav link. No email signup for Mochi (the app is live) — the hero CTA is the
// App Store button, so we don't need Clarity's success/error/subscribed flags.
struct PageContext: Content {
    var activePage: String
}

// Context for the /join/:code invite page — the room code is rendered large
// for manual entry and embedded in the mochi:// deep link.
struct JoinPageContext: Content {
    var activePage: String
    var roomCode: String
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

    // MARK: - Join links (universal-link landing page, no auth)
    // https://playmochiapp.com/join/WOLF-42 — shared from the app's lobby.
    // On devices with Mochi installed the universal link opens the app
    // directly; everyone else lands here with a deep-link button, an App
    // Store fallback, and the code shown large for manual entry.
    app.get("join", ":code") { req async throws -> View in
        let raw = req.parameters.get("code") ?? ""
        // Room codes are short "WORD-42" strings — keep only ASCII
        // letters/digits/dash so the page never reflects arbitrary input.
        let code = String(raw.uppercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        })
        guard !code.isEmpty, code.count <= 12 else {
            throw Abort(.notFound)
        }
        return try await req.view.render(
            "join", JoinPageContext(activePage: "join", roomCode: code)
        )
    }

    // MARK: - Universal links (apple-app-site-association)
    // Apple's CDN fetches this to associate /join/* with the app. Must be
    // served as application/json with no redirect. FileMiddleware only matches
    // real files under Public/, so this dynamic route handles the path. The
    // team id rides on APNS_TEAM_ID (already set in prod); when it's unset
    // (local dev) the file 404s and universal links are simply off.
    app.grouped(".well-known").get("apple-app-site-association") { req -> Response in
        guard let teamID = Environment.get("APNS_TEAM_ID") else {
            throw Abort(.notFound)
        }
        struct AASA: Encodable {
            struct Applinks: Encodable {
                struct Detail: Encodable {
                    let appID: String
                    let paths: [String]
                }
                let apps: [String]
                let details: [Detail]
            }
            let applinks: Applinks
        }
        let payload = AASA(applinks: .init(
            apps: [],
            details: [.init(
                appID: "\(teamID).com.relentlessforgellc.mochi",
                paths: ["/join/*"]
            )]
        ))
        let data = try JSONEncoder().encode(payload)
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }

    // S1/S2 — account / identity endpoints (bootstrap, apple-link).
    try app.register(collection: AccountController())

    // S3 — authenticated read endpoints (GET /me/stats, /me/history).
    try app.register(collection: MeController())

    // Friends + challenges (auth), the public /leaderboard, and /leaderboard/me.
    try app.register(collection: FriendsController())

    // Friend groups — private leaderboards joined via invite code (auth).
    try app.register(collection: GroupsController())

    // Daily coin gifts between friends (auth).
    try app.register(collection: GiftsController())

    // APNs token registration (device-resolved, no bearer — see controller).
    try app.register(collection: PushController())

    // WebSocket route registered outside any auth middleware.
    // WS upgrade requests cannot carry Authorization headers —
    // identity is established via the one-time token in the query string.
    app.webSocket("game", "ws") { req, ws in
        controller.handleWebSocket(req: req, ws: ws)
    }

    app.get("health") { _ in ["status": "ok"] }
}
