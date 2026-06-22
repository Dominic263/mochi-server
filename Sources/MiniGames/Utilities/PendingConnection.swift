import Foundation

// MARK: - PendingConnection
// Holds the identity we established during the HTTP phase
// so the WebSocket handler knows who is connecting without
// needing auth headers (which WS upgrade requests cannot carry).
struct PendingConnection {
    let playerID: String
    let roomCode: String
    let role: PlayerRole
    let displayName: String
    // True only for tokens minted by /game/reconnect. Lets the WS handler
    // send the state snapshot immediately and skip the spurious opponentJoined.
    var isReconnect: Bool = false
}

// MARK: - PendingConnections
// Plain class with NSLock — called from NIO callbacks, no async needed.
// Tokens are single-use: consume() removes the token immediately so it
// cannot be replayed.
final class PendingConnections {
    nonisolated(unsafe) static let shared = PendingConnections()
    private init() {}

    private var store: [String: PendingConnection] = [:]
    private let lock = NSLock()

    func add(token: String, connection: PendingConnection) {
        lock.withLock {
            store[token] = connection
        }
    }

    /// Removes and returns the connection for this token.
    /// Returns nil if the token is unknown or already consumed.
    func consume(token: String) -> PendingConnection? {
        lock.withLock {
            store.removeValue(forKey: token)
        }
    }
}
