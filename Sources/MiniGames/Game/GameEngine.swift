import Foundation

// MARK: - Engine errors

enum EngineError: Error, CustomStringConvertible {
    case wrongPhase(expected: GamePhase, actual: GamePhase)
    case wrongPlayer
    case secretNotSet
    case questionAlreadyPending
    case noPendingQuestion

    var description: String {
        switch self {
        case .wrongPhase(let expected, let actual):
            return "Wrong phase: expected \(expected), was \(actual)"
        case .wrongPlayer:
            return "It is not your turn"
        case .secretNotSet:
            return "Answerer has not set a secret yet"
        case .questionAlreadyPending:
            return "Wait for the current question to be answered"
        case .noPendingQuestion:
            return "There is no pending question to answer"
        }
    }
}

// MARK: - Engine result

struct EngineResult {
    let state: GameState
    let toAnswerer: GameEventEnvelope?
    let toQuestioner: GameEventEnvelope?
    let toBoth: GameEventEnvelope?
    let closeConnections: Bool

    init(
        state: GameState,
        toAnswerer: GameEventEnvelope? = nil,
        toQuestioner: GameEventEnvelope? = nil,
        toBoth: GameEventEnvelope? = nil,
        closeConnections: Bool = false
    ) {
        self.state = state
        self.toAnswerer = toAnswerer
        self.toQuestioner = toQuestioner
        self.toBoth = toBoth
        self.closeConnections = closeConnections
    }
}

// MARK: - Engine

struct GameEngine {

    private static let freeHintUnlockCount = 10
    private static let maxRewardedHintsPerGame = 3

    static func process(
        action: GameActionEnvelope,
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        switch action.payload {
        case .setSecret(let p):
            return try handleSetSecret(p, playerID: playerID, state: state)

        case .askQuestion(let p):
            return try handleAskQuestion(p, playerID: playerID, state: state)

        case .answerQuestion(let p):
            return try handleAnswerQuestion(p, playerID: playerID, state: state)

        case .makeGuess(let p):
            return try handleMakeGuess(p, playerID: playerID, state: state)

        case .requestRestart:
            return try handleRequestRestart(playerID: playerID, state: state)

        case .confirmRestart:
            return EngineResult(state: state)

        case .startGame:
            return try handleStartGame(playerID: playerID, state: state)

        case .dismissGame:
            return EngineResult(state: state)

        case .requestHint:
            return try handleRequestHint(playerID: playerID, state: state)

        case .requestRewardedHint:
            return try handleRequestRewardedHint(playerID: playerID, state: state)

        case .provideHint(let p):
            return try handleProvideHint(p, playerID: playerID, state: state)
        }
    }

    // MARK: - Core handlers

    private static func handleSetSecret(
        _ payload: SetSecretPayload,
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .lobby else {
            throw EngineError.wrongPhase(expected: .lobby, actual: state.phase)
        }

        guard playerID == state.answererID else {
            throw EngineError.wrongPlayer
        }

        var next = state
        next.secret = payload.secret

        return EngineResult(
            state: next,
            toAnswerer: .stateSnapshot(next.answererView()),
            toQuestioner: .secretSet()
        )
    }

    private static func handleAskQuestion(
        _ payload: AskQuestionPayload,
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .playing else {
            throw EngineError.wrongPhase(expected: .playing, actual: state.phase)
        }

        guard playerID == state.questionerID else {
            throw EngineError.wrongPlayer
        }

        guard state.secret != nil else {
            throw EngineError.secretNotSet
        }

        if let last = state.questionsAsked.last, last.answer == nil {
            throw EngineError.questionAlreadyPending
        }

        var next = state

        let qna = QnA(
            id: UUID(),
            questionNumber: next.questionsAsked.count + 1,
            question: payload.question,
            answer: nil
        )

        next.questionsAsked.append(qna)

        return EngineResult(
            state: next,
            toBoth: .questionAsked(qna)
        )
    }

    private static func handleAnswerQuestion(
        _ payload: AnswerQuestionPayload,
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .playing else {
            throw EngineError.wrongPhase(expected: .playing, actual: state.phase)
        }

        guard playerID == state.answererID else {
            throw EngineError.wrongPlayer
        }

        guard var lastQnA = state.questionsAsked.last, lastQnA.answer == nil else {
            throw EngineError.noPendingQuestion
        }

        lastQnA.answer = payload.answer ? "Yes" : "No"

        var next = state
        next.questionsAsked[next.questionsAsked.count - 1] = lastQnA
        next.questionsRemaining -= 1

        if next.questionsRemaining == 0 {
            next.phase = .lost

            return EngineResult(
                state: next,
                toBoth: .gameLost(secret: next.secret ?? "")
            )
        }

        return EngineResult(
            state: next,
            toAnswerer: .stateSnapshot(next.answererView()),
            toQuestioner: .stateSnapshot(next.questionerView()),
            toBoth: .answerGiven(lastQnA)
        )
    }

    private static func handleMakeGuess(
        _ payload: MakeGuessPayload,
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .playing else {
            throw EngineError.wrongPhase(expected: .playing, actual: state.phase)
        }

        guard playerID == state.questionerID else {
            throw EngineError.wrongPlayer
        }

        guard let secret = state.secret else {
            throw EngineError.secretNotSet
        }

        let guessNorm = payload.guess.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz").inverted)
            .joined()

        let secretNorm = secret.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz").inverted)
            .joined()

        let correct = guessNorm == secretNorm

        var next = state

        if correct {
            next.phase = .won

            return EngineResult(
                state: next,
                toBoth: .gameWon(
                    secret: secret,
                    questionsUsed: 20 - next.questionsRemaining
                )
            )
        }

        let distance = levenshtein(guessNorm, secretNorm)

        let feedback: String
        switch distance {
        case 1:
            feedback = "Almost! Just a spelling mistake 🔤"
        case 2:
            feedback = "So close! Check your spelling 🔥"
        case 3...4:
            feedback = "You're in the right area, keep going 💭"
        default:
            feedback = "No — keep trying"
        }

        next.questionsRemaining -= 1

        let guessQnA = QnA(
            id: UUID(),
            questionNumber: next.questionsAsked.count + 1,
            question: "Guess: \(payload.guess)",
            answer: feedback
        )

        next.questionsAsked.append(guessQnA)

        if next.questionsRemaining == 0 {
            next.phase = .lost

            return EngineResult(
                state: next,
                toBoth: .gameLost(secret: secret)
            )
        }

        return EngineResult(
            state: next,
            toAnswerer: .stateSnapshot(next.answererView()),
            toQuestioner: .stateSnapshot(next.questionerView()),
            toBoth: .answerGiven(guessQnA)
        )
    }

    // MARK: - Hint handlers

    private static func handleRequestHint(
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .playing else {
            throw EngineError.wrongPhase(expected: .playing, actual: state.phase)
        }

        guard playerID == state.questionerID else {
            throw EngineError.wrongPlayer
        }

        guard state.questionsAsked.count >= freeHintUnlockCount else {
            return EngineResult(
                state: state,
                toQuestioner: .error("Hints unlock after 10 questions or guesses.")
            )
        }

        guard state.freeHintsRemaining > 0 else {
            return EngineResult(
                state: state,
                toQuestioner: .error("No free hints remaining.")
            )
        }

        return requestHintCore(
            state: state,
            consumeFreeHint: true
        )
    }

    private static func handleRequestRewardedHint(
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .playing else {
            throw EngineError.wrongPhase(expected: .playing, actual: state.phase)
        }

        guard playerID == state.questionerID else {
            throw EngineError.wrongPlayer
        }

        guard state.questionsAsked.count >= freeHintUnlockCount else {
            return EngineResult(
                state: state,
                toQuestioner: .error("Rewarded hints unlock after 10 questions or guesses.")
            )
        }

        guard state.freeHintsRemaining == 0 else {
            return EngineResult(
                state: state,
                toQuestioner: .error("Use your free hints first.")
            )
        }

        guard state.rewardedHintsUsedCount < maxRewardedHintsPerGame else {
            return EngineResult(
                state: state,
                toQuestioner: .error("No rewarded hints remaining.")
            )
        }

        return requestHintCore(
            state: state,
            consumeFreeHint: false
        )
    }

    private static func requestHintCore(
        state: GameState,
        consumeFreeHint: Bool
    ) -> EngineResult {
        guard state.hintPending == false else {
            return EngineResult(
                state: state,
                toQuestioner: .error("A hint is already pending.")
            )
        }

        if let lastHintQuestionCount = state.lastHintQuestionCount,
           state.questionsAsked.count <= lastHintQuestionCount {
            return EngineResult(
                state: state,
                toQuestioner: .error("Ask a question or make a guess before using another hint.")
            )
        }

        var next = state

        if consumeFreeHint {
            next.freeHintsRemaining -= 1
        } else {
            // One ad = one hint. It is consumed immediately by this request.
            next.rewardedHintsUsedCount += 1
        }

        next.hintPending = true
        next.lastHintQuestionCount = next.questionsAsked.count

        return EngineResult(
            state: next,
            toAnswerer: .hintRequested(),
            toQuestioner: .stateSnapshot(next.questionerView())
        )
    }

    private static func handleProvideHint(
        _ payload: ProvideHintPayload,
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .playing else {
            throw EngineError.wrongPhase(expected: .playing, actual: state.phase)
        }

        guard playerID == state.answererID else {
            throw EngineError.wrongPlayer
        }

        guard state.hintPending else {
            return EngineResult(state: state)
        }

        var next = state
        next.hintPending = false

        return EngineResult(
            state: next,
            toAnswerer: .stateSnapshot(next.answererView()),
            toQuestioner: .hintGiven(
                hint: payload.hint,
                hintsRemaining: next.freeHintsRemaining
            )
        )
    }

    // MARK: - Restart

    private static func handleRequestRestart(
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard state.phase == .won || state.phase == .lost || state.phase == .waitingForRematch else {
            throw EngineError.wrongPhase(expected: .won, actual: state.phase)
        }

        var next = state

        if next.restartRequestedBy == nil {
            next.phase = .waitingForRematch
            next.restartRequestedBy = playerID

            let toAnswerer: GameEventEnvelope? = playerID == state.answererID ? nil : .restartRequested()
            let toQuestioner: GameEventEnvelope? = playerID == state.questionerID ? nil : .restartRequested()

            return EngineResult(
                state: next,
                toAnswerer: toAnswerer,
                toQuestioner: toQuestioner
            )
        }

        guard next.restartRequestedBy != playerID else {
            return EngineResult(state: next)
        }

        let newAnswererID = next.questionerID ?? next.answererID
        let newAnswererDisplayName = next.questionerDisplayName ?? next.answererDisplayName
        let newQuestionerID = next.answererID
        let newQuestionerDisplayName = next.answererDisplayName

        var fresh = GameState(
            roomCode: state.roomCode,
            answererID: newAnswererID,
            answererDisplayName: newAnswererDisplayName
        )

        fresh.questionerID = newQuestionerID
        fresh.questionerDisplayName = newQuestionerDisplayName
        fresh.phase = .lobby

        return EngineResult(
            state: fresh,
            toAnswerer: .gameRestarted(fresh.answererView()),
            toQuestioner: .gameRestarted(fresh.questionerView())
        )
    }

    private static func handleStartGame(
        playerID: String,
        state: GameState
    ) throws -> EngineResult {
        guard playerID == state.answererID else {
            throw EngineError.wrongPlayer
        }

        guard state.secret != nil else {
            throw EngineError.secretNotSet
        }

        guard state.phase == .lobby else {
            return EngineResult(state: state)
        }

        var next = state
        next.phase = .playing

        return EngineResult(
            state: next,
            toAnswerer: .stateSnapshot(next.answererView()),
            toQuestioner: .stateSnapshot(next.questionerView()),
            toBoth: .gameStarted()
        )
    }

    // MARK: - Levenshtein distance

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)

        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var dp = Array(
            repeating: Array(repeating: 0, count: n + 1),
            count: m + 1
        )

        for i in 0...m {
            dp[i][0] = i
        }

        for j in 0...n {
            dp[0][j] = j
        }

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(
                        dp[i - 1][j],
                        dp[i][j - 1],
                        dp[i - 1][j - 1]
                    )
                }
            }
        }

        return dp[m][n]
    }
}
