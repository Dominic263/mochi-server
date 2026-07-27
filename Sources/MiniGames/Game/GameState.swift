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

    // MARK: Timer state (server-enforced clocks)
    //
    // All three are OPTIONAL so old persisted state_json rows (which lack these
    // keys) still decode, and so shipped clients — which ignore unknown snapshot
    // fields — keep working unchanged.

    /// Wall-clock deadline for the whole match (20 minutes from startGame).
    /// Nil = no match clock running.
    var matchDeadline: Date?

    /// Wall-clock deadline for the current turn (60 seconds, reset by every
    /// state-advancing action). Nil = no turn clock running.
    var turnDeadline: Date?

    /// Answerer slow-play strikes. Nil means 0; the third strike forfeits.
    var answererStrikes: Int?

    /// True once the questioner has spent their one rewarded-ad time
    /// extension (+5 minutes on the match clock).
    var matchExtensionUsed: Bool?

    /// Set while a hint is pending — the match clock freezes at this instant
    /// so the questioner isn't billed for the answerer's hint-writing time.
    var hintRequestedAt: Date?

    /// Set while a player is watching a rewarded ad (suggestion refresh, time
    /// extension) — BOTH clocks freeze at this instant. endAdPause (or the
    /// sweep's 120s auto-expiry) credits the paused time back to both
    /// deadlines. Optional for backward-compatible state_json decoding.
    var adPausedAt: Date?

    /// Who started the current ad pause — only they (or the sweep) may end it.
    var adPausedBy: String?

    /// Ad pauses spent this game (nil = 0). Hard cap so the pause can never
    /// become a free stall button.
    var adPausesUsed: Int?

    // MARK: Lobby/chat appearance (additive)
    //
    // Each seat's avatar + equipped cosmetics, threaded in from the create/join
    // HTTP bodies (or fixed per difficulty for the AI seat). ALL optional so
    // old persisted state_json rows — and old clients that never send them —
    // keep decoding unchanged.

    var answererAvatarID: String?
    var answererHeadwear: String?
    var answererEyewear: String?
    var answererNeckwear: String?

    var questionerAvatarID: String?
    var questionerHeadwear: String?
    var questionerEyewear: String?
    var questionerNeckwear: String?

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

        case matchDeadline
        case turnDeadline
        case answererStrikes
        case matchExtensionUsed
        case hintRequestedAt
        case adPausedAt
        case adPausedBy
        case adPausesUsed

        case answererAvatarID
        case answererHeadwear
        case answererEyewear
        case answererNeckwear
        case questionerAvatarID
        case questionerHeadwear
        case questionerEyewear
        case questionerNeckwear

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

        self.matchDeadline = try container.decodeIfPresent(Date.self, forKey: .matchDeadline)
        self.turnDeadline = try container.decodeIfPresent(Date.self, forKey: .turnDeadline)
        self.answererStrikes = try container.decodeIfPresent(Int.self, forKey: .answererStrikes)
        self.matchExtensionUsed = try container.decodeIfPresent(Bool.self, forKey: .matchExtensionUsed)
        self.hintRequestedAt = try container.decodeIfPresent(Date.self, forKey: .hintRequestedAt)
        self.adPausedAt = try container.decodeIfPresent(Date.self, forKey: .adPausedAt)
        self.adPausedBy = try container.decodeIfPresent(String.self, forKey: .adPausedBy)
        self.adPausesUsed = try container.decodeIfPresent(Int.self, forKey: .adPausesUsed)

        self.answererAvatarID = try container.decodeIfPresent(String.self, forKey: .answererAvatarID)
        self.answererHeadwear = try container.decodeIfPresent(String.self, forKey: .answererHeadwear)
        self.answererEyewear = try container.decodeIfPresent(String.self, forKey: .answererEyewear)
        self.answererNeckwear = try container.decodeIfPresent(String.self, forKey: .answererNeckwear)
        self.questionerAvatarID = try container.decodeIfPresent(String.self, forKey: .questionerAvatarID)
        self.questionerHeadwear = try container.decodeIfPresent(String.self, forKey: .questionerHeadwear)
        self.questionerEyewear = try container.decodeIfPresent(String.self, forKey: .questionerEyewear)
        self.questionerNeckwear = try container.decodeIfPresent(String.self, forKey: .questionerNeckwear)
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

        try container.encodeIfPresent(matchDeadline, forKey: .matchDeadline)
        try container.encodeIfPresent(turnDeadline, forKey: .turnDeadline)
        try container.encodeIfPresent(answererStrikes, forKey: .answererStrikes)
        try container.encodeIfPresent(matchExtensionUsed, forKey: .matchExtensionUsed)
        try container.encodeIfPresent(hintRequestedAt, forKey: .hintRequestedAt)
        try container.encodeIfPresent(adPausedAt, forKey: .adPausedAt)
        try container.encodeIfPresent(adPausedBy, forKey: .adPausedBy)
        try container.encodeIfPresent(adPausesUsed, forKey: .adPausesUsed)

        try container.encodeIfPresent(answererAvatarID, forKey: .answererAvatarID)
        try container.encodeIfPresent(answererHeadwear, forKey: .answererHeadwear)
        try container.encodeIfPresent(answererEyewear, forKey: .answererEyewear)
        try container.encodeIfPresent(answererNeckwear, forKey: .answererNeckwear)
        try container.encodeIfPresent(questionerAvatarID, forKey: .questionerAvatarID)
        try container.encodeIfPresent(questionerHeadwear, forKey: .questionerHeadwear)
        try container.encodeIfPresent(questionerEyewear, forKey: .questionerEyewear)
        try container.encodeIfPresent(questionerNeckwear, forKey: .questionerNeckwear)
    }

    // MARK: Turn ownership

    /// Whose move it is right now: a trailing unanswered question or a pending
    /// hint request puts the ball in the answerer's court; otherwise the
    /// questioner is up.
    var currentTurnRole: PlayerRole {
        if hintPending { return .answerer }
        if let last = questionsAsked.last, last.answer == nil { return .answerer }
        return .questioner
    }

    // MARK: Clock helpers (for snapshots)

    private func secondsRemaining(until deadline: Date?) -> Int? {
        guard phase == .playing, let deadline else { return nil }
        // While a hint is being written or an ad is playing, the clock is
        // FROZEN at the moment the pause began (the resume path credits the
        // elapsed time back). If both are somehow set, freeze at the earlier.
        let pauseStarts = [hintRequestedAt, adPausedAt].compactMap { $0 }
        if let pausedAt = pauseStarts.min() {
            return max(0, Int(deadline.timeIntervalSince(pausedAt).rounded()))
        }
        return max(0, Int(deadline.timeIntervalSinceNow.rounded()))
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
            },
            matchSecondsRemaining: secondsRemaining(until: matchDeadline),
            turnSecondsRemaining: secondsRemaining(until: turnDeadline),
            answererAvatarID: answererAvatarID,
            answererHeadwear: answererHeadwear,
            answererEyewear: answererEyewear,
            answererNeckwear: answererNeckwear,
            questionerAvatarID: questionerAvatarID,
            questionerHeadwear: questionerHeadwear,
            questionerEyewear: questionerEyewear,
            questionerNeckwear: questionerNeckwear
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
            secretWordCount: nil,
            matchSecondsRemaining: secondsRemaining(until: matchDeadline),
            turnSecondsRemaining: secondsRemaining(until: turnDeadline),
            answererAvatarID: answererAvatarID,
            answererHeadwear: answererHeadwear,
            answererEyewear: answererEyewear,
            answererNeckwear: answererNeckwear,
            questionerAvatarID: questionerAvatarID,
            questionerHeadwear: questionerHeadwear,
            questionerEyewear: questionerEyewear,
            questionerNeckwear: questionerNeckwear
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
    // Server-enforced clocks (additive; old clients ignore unknown keys).
    let matchSecondsRemaining: Int?
    let turnSecondsRemaining: Int?
    // Seat appearance (additive; old clients ignore unknown keys). Both views
    // carry BOTH seats so each player can render the OTHER player's avatar
    // and cosmetics in the lobby/chat.
    let answererAvatarID: String?
    let answererHeadwear: String?
    let answererEyewear: String?
    let answererNeckwear: String?
    let questionerAvatarID: String?
    let questionerHeadwear: String?
    let questionerEyewear: String?
    let questionerNeckwear: String?

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
        secretWordCount: Int? = nil,
        matchSecondsRemaining: Int? = nil,
        turnSecondsRemaining: Int? = nil,
        answererAvatarID: String? = nil,
        answererHeadwear: String? = nil,
        answererEyewear: String? = nil,
        answererNeckwear: String? = nil,
        questionerAvatarID: String? = nil,
        questionerHeadwear: String? = nil,
        questionerEyewear: String? = nil,
        questionerNeckwear: String? = nil
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
        self.matchSecondsRemaining = matchSecondsRemaining
        self.turnSecondsRemaining = turnSecondsRemaining
        self.answererAvatarID = answererAvatarID
        self.answererHeadwear = answererHeadwear
        self.answererEyewear = answererEyewear
        self.answererNeckwear = answererNeckwear
        self.questionerAvatarID = questionerAvatarID
        self.questionerHeadwear = questionerHeadwear
        self.questionerEyewear = questionerEyewear
        self.questionerNeckwear = questionerNeckwear
    }
}
