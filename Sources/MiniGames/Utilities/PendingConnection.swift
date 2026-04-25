import Foundation

// MARK: - PendingConnection

struct PendingConnection {
    let playerID: String
    let roomCode: String
    let role: PlayerRole
    let displayName: String
}

// MARK: - PendingConnections

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

    func consume(token: String) -> PendingConnection? {
        lock.withLock {
            store.removeValue(forKey: token)
        }
    }
}
