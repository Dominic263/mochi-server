import Vapor

func routes(_ app: Application) throws {
    let controller = MiniGameController()
    try app.register(collection: controller)

    // WebSocket route registered outside any auth middleware.
    // WS upgrade requests cannot carry Authorization headers —
    // identity is established via the one-time token in the query string.
    app.webSocket("game", "ws") { req, ws in
        controller.handleWebSocket(req: req, ws: ws)
    }
    
    app.get("health") { _ in ["status": "ok"] }
}
