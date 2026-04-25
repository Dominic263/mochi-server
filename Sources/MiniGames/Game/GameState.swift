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
    var hintsRemaining: Int  // starts at 3, decrements each time a hint is given
    var hintPending: Bool    // true when questioner requested a hint, AI polls this

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
        self.hintsRemaining = 3
        self.hintPending = false
    }

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
            hintsRemaining: hintsRemaining,
            secretWordCount: secret.map { s in s.components(separatedBy: " ").filter { !$0.isEmpty }.count }
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
            hintsRemaining: hintsRemaining
        )
    }

    func toJSON() -> String {
        guard
            let data = try? JSONEncoder().encode(self),
            let str = String(data: data, encoding: .utf8)
        else { return "{}" }
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
    let secretWordCount: Int?  // word count sent to questioner only

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
