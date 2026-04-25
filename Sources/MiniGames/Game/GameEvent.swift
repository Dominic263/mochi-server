import Foundation

// MARK: - Event types

enum GameEventType: String, Codable, Sendable {
    case stateSnapshot
    case opponentJoined
    case opponentLeft
    case secretSet
    case questionAsked
    case answerGiven
    case gameWon
    case gameLost
    case restartRequested
    case gameRestarted
    case gameStarted
    case hintRequested
    case hintGiven
    case typingIndicator  // opponent is thinking/typing
    case error
}

// MARK: - Payload types

struct OpponentJoinedPayload: Codable, Sendable { let displayName: String }
struct GameWonPayload: Codable, Sendable { let secret: String; let questionsUsed: Int }
struct GameLostPayload: Codable, Sendable { let secret: String }
struct HintPayload: Codable, Sendable { let hint: String; let hintsRemaining: Int }
struct GameErrorPayload: Codable, Sendable { let message: String }
struct EmptyPayload: Codable, Sendable {}

// MARK: - Envelope

struct GameEventEnvelope: Codable, Sendable {
    let type: GameEventType
    let payload: EncodablePayload

    struct EncodablePayload: Codable, Sendable {
        private let _encode: @Sendable (any Encoder) throws -> Void
        init<T: Encodable & Sendable>(_ value: T) { self._encode = { try value.encode(to: $0) } }
        func encode(to encoder: any Encoder) throws { try _encode(encoder) }
        init(from decoder: any Decoder) throws { self._encode = { _ in } }
    }

    init(type: GameEventType, payload: some Encodable & Sendable) {
        self.type = type
        self.payload = EncodablePayload(payload)
    }

    func toJSON() -> String {
        guard
            let data = try? JSONEncoder().encode(self),
            let str  = String(data: data, encoding: .utf8)
        else { return #"{"type":"error","payload":{"message":"encoding failed"}}"# }
        return str
    }
}

// MARK: - Convenience builders

extension GameEventEnvelope {
    static func stateSnapshot(_ view: GameStateView) -> GameEventEnvelope {
        .init(type: .stateSnapshot, payload: view)
    }
    static func opponentJoined(displayName: String) -> GameEventEnvelope {
        .init(type: .opponentJoined, payload: OpponentJoinedPayload(displayName: displayName))
    }
    static func opponentLeft() -> GameEventEnvelope {
        .init(type: .opponentLeft, payload: EmptyPayload())
    }
    static func secretSet() -> GameEventEnvelope {
        .init(type: .secretSet, payload: EmptyPayload())
    }
    static func questionAsked(_ qna: QnA) -> GameEventEnvelope {
        .init(type: .questionAsked, payload: qna)
    }
    static func answerGiven(_ qna: QnA) -> GameEventEnvelope {
        .init(type: .answerGiven, payload: qna)
    }
    static func gameWon(secret: String, questionsUsed: Int) -> GameEventEnvelope {
        .init(type: .gameWon, payload: GameWonPayload(secret: secret, questionsUsed: questionsUsed))
    }
    static func gameLost(secret: String) -> GameEventEnvelope {
        .init(type: .gameLost, payload: GameLostPayload(secret: secret))
    }
    static func restartRequested() -> GameEventEnvelope {
        .init(type: .restartRequested, payload: EmptyPayload())
    }
    static func gameRestarted(_ view: GameStateView) -> GameEventEnvelope {
        .init(type: .gameRestarted, payload: view)
    }
    static func gameStarted() -> GameEventEnvelope {
        .init(type: .gameStarted, payload: EmptyPayload())
    }
    static func hintRequested() -> GameEventEnvelope {
        .init(type: .hintRequested, payload: EmptyPayload())
    }
    static func hintGiven(hint: String, hintsRemaining: Int) -> GameEventEnvelope {
        .init(type: .hintGiven, payload: HintPayload(hint: hint, hintsRemaining: hintsRemaining))
    }
    static func typingIndicator() -> GameEventEnvelope {
        .init(type: .typingIndicator, payload: EmptyPayload())
    }
    static func error(_ message: String) -> GameEventEnvelope {
        .init(type: .error, payload: GameErrorPayload(message: message))
    }
}
