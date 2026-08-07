import Foundation
import Testing

@testable import MiniGames

// The lobby join handshake. This is the path that used to strand friend games:
// the answerer learned their opponent had arrived from ONE fire-once
// opponentJoined event, so a host who was away sharing the room code never
// found out, and the Start button stayed disabled forever.

private struct Collector: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        var messages: [[String: Any]] = []
        let lock = NSLock()
    }
    private let box = Box()

    var send: @Sendable (String) -> Void {
        { json in
            guard
                let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            self.box.lock.withLock { self.box.messages.append(obj) }
        }
    }

    var messages: [[String: Any]] {
        box.lock.withLock { box.messages }
    }

    var types: [String] {
        messages.compactMap { $0["type"] as? String }
    }

    func lastSnapshotPayload() -> [String: Any]? {
        messages.last { ($0["type"] as? String) == "stateSnapshot" }?["payload"] as? [String: Any]
    }

    /// The manager dispatches on its own concurrent queue, so give it a beat.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(200))
    }
}

@Test func answererGetsOpeningSnapshotOnConnect() async throws {
    let code = "TEST-\(Int.random(in: 1000...9999))"
    let state = GameState(roomCode: code, answererID: "A", answererDisplayName: "Ansel")
    WebSocketManager.shared.createRoom(state: state)
    defer { WebSocketManager.shared.removeRoom(code: code) }

    let answerer = Collector()
    let id = WebSocketManager.shared.connectAnswerer(roomCode: code, send: answerer.send)
    await answerer.settle()

    #expect(id != nil)
    // The snapshot must land as part of connecting — the client's whole lobby
    // (secret prompt, opponent state) is driven off it.
    #expect(answerer.types == ["stateSnapshot"])
    let payload = try #require(answerer.lastSnapshotPayload())
    #expect(payload["phase"] as? String == "lobby")
    #expect(payload["opponentConnected"] as? Bool == false)
}

@Test func questionerJoinTellsAnswererWithBothEventAndSnapshot() async throws {
    let code = "TEST-\(Int.random(in: 1000...9999))"
    var state = GameState(roomCode: code, answererID: "A", answererDisplayName: "Ansel")
    state.secret = "toothbrush"
    WebSocketManager.shared.createRoom(state: state)
    defer { WebSocketManager.shared.removeRoom(code: code) }

    let answerer = Collector()
    WebSocketManager.shared.connectAnswerer(roomCode: code, send: answerer.send)
    await answerer.settle()

    let questioner = Collector()
    _ = WebSocketManager.shared.connectQuestioner(
        roomCode: code,
        playerID: "B",
        displayName: "Quinn",
        send: questioner.send
    )
    WebSocketManager.shared.announceQuestionerJoined(roomCode: code, displayName: "Quinn")
    await answerer.settle()

    // The event still fires (clients react to it for the "Quinn joined" copy)…
    #expect(answerer.types.contains("opponentJoined"))
    // …but the snapshot behind it is what makes the lobby recoverable: an
    // answerer who missed the event can reconnect and read the truth instead.
    let payload = try #require(answerer.lastSnapshotPayload())
    #expect(payload["opponentConnected"] as? Bool == true)
    #expect(payload["secretConfirmed"] as? Bool == true)
    #expect(payload["opponentDisplayName"] as? String == "Quinn")
}

@Test func reconnectingAnswererImmediatelySeesTheWaitingOpponent() async throws {
    let code = "TEST-\(Int.random(in: 1000...9999))"
    var state = GameState(roomCode: code, answererID: "A", answererDisplayName: "Ansel")
    state.secret = "toothbrush"
    WebSocketManager.shared.createRoom(state: state)
    defer { WebSocketManager.shared.removeRoom(code: code) }

    // Host connects, then drops — exactly what iOS does while they are off
    // sharing the room code.
    let firstSocket = Collector()
    let firstID = WebSocketManager.shared.connectAnswerer(roomCode: code, send: firstSocket.send)
    _ = WebSocketManager.shared.disconnect(roomCode: code, role: .answerer, connectionID: firstID)

    // The friend arrives while the host is away: the event goes nowhere.
    let questioner = Collector()
    _ = WebSocketManager.shared.connectQuestioner(
        roomCode: code, playerID: "B", displayName: "Quinn", send: questioner.send
    )
    WebSocketManager.shared.announceQuestionerJoined(roomCode: code, displayName: "Quinn")
    await firstSocket.settle()
    #expect(!firstSocket.types.contains("opponentJoined"))

    // The client's lobby watchdog re-opens the socket, and one snapshot is
    // enough to unblock the Start button.
    let secondSocket = Collector()
    WebSocketManager.shared.connectAnswerer(roomCode: code, send: secondSocket.send)
    await secondSocket.settle()

    let payload = try #require(secondSocket.lastSnapshotPayload())
    #expect(payload["opponentConnected"] as? Bool == true)
    #expect(payload["secretConfirmed"] as? Bool == true)
}
