import Foundation

// MARK: - Roles

enum PlayerRole: String, Codable {
    case answerer
    case questioner
}

// MARK: - Game phase

enum GamePhase: String, Codable, Equatable {
    case lobby
    case playing
    case won
    case lost
    case waitingForRematch
}

// MARK: - Q&A pair

struct QnA: Codable {
    let id: UUID
    let questionNumber: Int
    let question: String
    var answer: String?
}

// MARK: - Core state

struct GameState: Codable {
    var roomCode: String
    var phase: GamePhase

    var answererID: String
    var answererDisplayName: String

    var questionerID: String?
    var questionerDisplayName: String?

    var secret: String?
    var questionsAsked: [QnA]
    var questionsRemaining: Int

    var restartRequestedBy: String?

    // MARK: Hint state

    /// Free hints only. Starts at 3 and never refills.
    var freeHintsRemaining: Int

    /// Number of rewarded-ad hints already used this game.
    /// Server-side cap so the client cannot fake unlimited rewarded hints.
    var rewardedHintsUsedCount: Int

    /// True after a hint is requested and before the answerer provides it.
    var hintPending: Bool

    /// The question/guess count when the last hint was requested.
    /// Prevents consecutive hints without another question or guess.
    var lastHintQuestionCount: Int?

    init(roomCode: String, answererID: String, answererDisplayName: String) {
        self.roomCode = roomCode
        self.phase = .lobby

        self.answererID = answererID
        self.answererDisplayName = answererDisplayName

        self.questionerID = nil
        self.questionerDisplayName = nil

        self.secret = nil
        self.questionsAsked = []
        self.questionsRemaining = 20

        self.restartRequestedBy = nil

        self.freeHintsRemaining = 3
        self.rewardedHintsUsedCount = 0
        self.hintPending = false
        self.lastHintQuestionCount = nil
    }

    // MARK: Backward-compatible decoding

    enum CodingKeys: String, CodingKey {
        case roomCode
        case phase
        case answererID
        case answererDisplayName
        case questionerID
        case questionerDisplayName
        case secret
        case questionsAsked
        case questionsRemaining
        case restartRequestedBy

        case freeHintsRemaining
        case rewardedHintsUsedCount
        case hintPending
        case lastHintQuestionCount

        // Old field name from previous server state.
        case hintsRemaining
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.roomCode = try container.decode(String.self, forKey: .roomCode)
        self.phase = try container.decode(GamePhase.self, forKey: .phase)

        self.answererID = try container.decode(String.self, forKey: .answererID)
        self.answererDisplayName = try container.decode(String.self, forKey: .answererDisplayName)

        self.questionerID = try container.decodeIfPresent(String.self, forKey: .questionerID)
        self.questionerDisplayName = try container.decodeIfPresent(String.self, forKey: .questionerDisplayName)

        self.secret = try container.decodeIfPresent(String.self, forKey: .secret)
        self.questionsAsked = try container.decode([QnA].self, forKey: .questionsAsked)
        self.questionsRemaining = try container.decode(Int.self, forKey: .questionsRemaining)

        self.restartRequestedBy = try container.decodeIfPresent(String.self, forKey: .restartRequestedBy)

        // Prefer the new field. Fall back to old `hintsRemaining` if rehydrating older sessions.
        if let freeHintsRemaining = try container.decodeIfPresent(Int.self, forKey: .freeHintsRemaining) {
            self.freeHintsRemaining = freeHintsRemaining
        } else if let oldHintsRemaining = try container.decodeIfPresent(Int.self, forKey: .hintsRemaining) {
            self.freeHintsRemaining = oldHintsRemaining
        } else {
            self.freeHintsRemaining = 3
        }

        self.rewardedHintsUsedCount = try container.decodeIfPresent(Int.self, forKey: .rewardedHintsUsedCount) ?? 0
        self.hintPending = try container.decodeIfPresent(Bool.self, forKey: .hintPending) ?? false
        self.lastHintQuestionCount = try container.decodeIfPresent(Int.self, forKey: .lastHintQuestionCount)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(roomCode, forKey: .roomCode)
        try container.encode(phase, forKey: .phase)

        try container.encode(answererID, forKey: .answererID)
        try container.encode(answererDisplayName, forKey: .answererDisplayName)

        try container.encodeIfPresent(questionerID, forKey: .questionerID)
        try container.encodeIfPresent(questionerDisplayName, forKey: .questionerDisplayName)

        try container.encodeIfPresent(secret, forKey: .secret)
        try container.encode(questionsAsked, forKey: .questionsAsked)
        try container.encode(questionsRemaining, forKey: .questionsRemaining)

        try container.encodeIfPresent(restartRequestedBy, forKey: .restartRequestedBy)

        try container.encode(freeHintsRemaining, forKey: .freeHintsRemaining)
        try container.encode(rewardedHintsUsedCount, forKey: .rewardedHintsUsedCount)
        try container.encode(hintPending, forKey: .hintPending)
        try container.encodeIfPresent(lastHintQuestionCount, forKey: .lastHintQuestionCount)
    }

    // MARK: Views

    func questionerView() -> GameStateView {
        GameStateView(
            roomCode: roomCode,
            phase: phase,
            myRole: .questioner,
            opponentConnected: true,
            secretConfirmed: secret != nil,
            secret: nil,
            questionsAsked: questionsAsked,
            questionsRemaining: questionsRemaining,
            opponentDisplayName: answererDisplayName,
            hintsRemaining: freeHintsRemaining,
            secretWordCount: secret.map { secret in
                secret
                    .components(separatedBy: " ")
                    .filter { !$0.isEmpty }
                    .count
            }
        )
    }

    func answererView() -> GameStateView {
        GameStateView(
            roomCode: roomCode,
            phase: phase,
            myRole: .answerer,
            opponentConnected: questionerID != nil,
            secretConfirmed: secret != nil,
            secret: secret,
            questionsAsked: questionsAsked,
            questionsRemaining: questionsRemaining,
            opponentDisplayName: questionerDisplayName,
            hintsRemaining: freeHintsRemaining,
            secretWordCount: nil
        )
    }

    func toJSON() -> String {
        guard
            let data = try? JSONEncoder().encode(self),
            let str = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return str
    }
}

// MARK: - View sent to clients

struct GameStateView: Codable {
    let roomCode: String
    let phase: GamePhase
    let myRole: PlayerRole
    let opponentConnected: Bool
    let secretConfirmed: Bool
    let secret: String?
    let questionsAsked: [QnA]
    let questionsRemaining: Int
    let opponentDisplayName: String?
    let hintsRemaining: Int
    let secretWordCount: Int?

    init(
        roomCode: String,
        phase: GamePhase,
        myRole: PlayerRole,
        opponentConnected: Bool,
        secretConfirmed: Bool,
        secret: String? = nil,
        questionsAsked: [QnA] = [],
        questionsRemaining: Int = 20,
        opponentDisplayName: String? = nil,
        hintsRemaining: Int = 3,
        secretWordCount: Int? = nil
    ) {
        self.roomCode = roomCode
        self.phase = phase
        self.myRole = myRole
        self.opponentConnected = opponentConnected
        self.secretConfirmed = secretConfirmed
        self.secret = secret
        self.questionsAsked = questionsAsked
        self.questionsRemaining = questionsRemaining
        self.opponentDisplayName = opponentDisplayName
        self.hintsRemaining = hintsRemaining
        self.secretWordCount = secretWordCount
    }
}
