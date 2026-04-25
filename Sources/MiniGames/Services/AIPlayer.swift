import Foundation
import Vapor

// MARK: - AIPlayer

actor AIPlayer {

    nonisolated let playerID: String
    nonisolated let roomCode: String
    nonisolated let role:     PlayerRole
    nonisolated let openAI:   OpenAIClient

    // Answerer state
    private var secret: String?

    // Questioner state
    private var gameState   = AIGameState()
    private var aiName      = AIPlayer.randomName()
    private var personality = AIPlayer.randomPersonality()

    // Shared
    private var didStartAsking      = false
    private var hintRequestInFlight = false
    private var eventContinuation:   AsyncStream<AIEventWrapper>.Continuation?

    init(playerID: String, roomCode: String, role: PlayerRole, openAI: OpenAIClient) {
        self.playerID = playerID
        self.roomCode = roomCode
        self.role     = role
        self.openAI   = openAI
    }

    // MARK: - Entry point

    func start(on app: Application) async {
        let (stream, continuation) = AsyncStream<AIEventWrapper>.makeStream()
        eventContinuation = continuation

        switch role {
        case .answerer:   await runAsAnswerer(app: app, stream: stream)
        case .questioner: await runAsQuestioner(app: app, stream: stream)
        }
    }

    func receiveEvent(_ json: String) {
        if let wrapper = AIEventWrapper(json: json) {
            eventContinuation?.yield(wrapper)
        }
    }

    // MARK: - Answerer flow

    private func runAsAnswerer(app: Application, stream: AsyncStream<AIEventWrapper>) async {
        let chosenSecret = await pickSecret(app: app)
        secret = chosenSecret
        app.logger.info("🤖 AI answerer chose secret: \(chosenSecret)")

        WebSocketManager.shared.registerAI(self, roomCode: roomCode)
        let aiID = playerID, code = roomCode

        WebSocketManager.shared.connectAnswerer(roomCode: code) { json in
            WebSocketManager.shared.routeToAI(playerID: aiID, roomCode: code, json: json)
        }

        sendAction(GameActionEnvelope.encoded(.setSecret(SetSecretPayload(secret: chosenSecret))),
                   app: app)

        for await wrapper in stream {
            switch wrapper.event {
            case .opponentJoined:
                if !didStartAsking {
                    if let state = WebSocketManager.shared.currentState(for: roomCode),
                       state.secret != nil, state.phase == .lobby {
                        didStartAsking = true
                        try? await Task.sleep(for: .milliseconds(800))
                        sendAction(GameActionEnvelope.encoded(.startGame), app: app)
                    }
                }
            case .stateSnapshot(let phase, let opponentConnected, let secretConfirmed):
                if phase == "lobby", opponentConnected, secretConfirmed, !didStartAsking {
                    didStartAsking = true
                    try? await Task.sleep(for: .milliseconds(600))
                    sendAction(GameActionEnvelope.encoded(.startGame), app: app)
                }
            case .questionAsked(_, _, let question):
                await answerQuestion(question: question, app: app)
            case .hintRequested:
                await generateHint(app: app)
            case .gameWon, .gameLost, .opponentLeft:
                eventContinuation?.finish()
                WebSocketManager.shared.removeAI(roomCode: roomCode)
                return
            default: break
            }
        }
    }

    // MARK: - Questioner flow

    private func runAsQuestioner(app: Application, stream: AsyncStream<AIEventWrapper>) async {
        let aiID = playerID, code = roomCode

        WebSocketManager.shared.registerAI(self, roomCode: code)

        _ = WebSocketManager.shared.connectQuestioner(
            roomCode: code, playerID: aiID, displayName: aiName
        ) { json in
            WebSocketManager.shared.routeToAI(playerID: aiID, roomCode: code, json: json)
        }

        WebSocketManager.shared.sendToAnswerer(
            in: code, event: .opponentJoined(displayName: aiName)
        )

        for await wrapper in stream {
            switch wrapper.event {

            case .gameStarted:
                guard !didStartAsking else { break }
                didStartAsking = true
                try? await Task.sleep(for: .milliseconds(1200))
                await takeTurn(app: app)

            case .stateSnapshot(let phase, _, _):
                if phase == "playing", !didStartAsking {
                    didStartAsking = true
                    try? await Task.sleep(for: .milliseconds(1000))
                    await takeTurn(app: app)
                }

            case .answerGiven(_, let question, let answer):
                gameState.record(question: question, answer: answer)
                app.logger.info("🤖 '\(question)' → '\(answer)' | ~\(gameState.estimatedCandidates) candidates")

                if answer == "Yes", let word = extractSpecificThing(from: question) {
                    app.logger.info("🤖 Specific-thing confirmed: '\(word)' — guessing immediately")
                    try? await Task.sleep(for: .milliseconds(900))
                    sendAction(GameActionEnvelope.encoded(
                        .makeGuess(MakeGuessPayload(guess: word))
                    ), app: app)
                    break
                }

                let delay = answer == "No"
                    ? Double.random(in: 1.8...3.5)
                    : Double.random(in: 0.9...2.2)
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                await takeTurn(app: app)

            case .hintGiven(_, let answer):
                gameState.recordHint(answer)
                hintRequestInFlight = false
                app.logger.info("🤖 AI received hint: \(answer)")
                try? await Task.sleep(for: .milliseconds(1200))
                await processHintAndAct(hint: answer, app: app)

            case .gameWon, .gameLost, .opponentLeft:
                eventContinuation?.finish()
                WebSocketManager.shared.removeAI(roomCode: roomCode)
                return

            default: break
            }
        }
    }

    // MARK: - Turn decision

    private func takeTurn(app: Application) async {
        guard let state = WebSocketManager.shared.currentState(for: roomCode) else { return }
        let remaining = state.questionsRemaining

        if gameState.shouldGuessNow(questionsRemaining: remaining) {
            await makeGuess(app: app, remaining: remaining)
        } else if gameState.shouldRequestHint(questionsRemaining: remaining),
                  !hintRequestInFlight {
            hintRequestInFlight = true
            app.logger.info("🤖 AI requesting hint at Q\(20 - remaining)")
            sendAction(GameActionEnvelope.encoded(.requestHint), app: app)
        } else {
            await askQuestion(app: app, remaining: remaining)
        }
    }

    // MARK: - Ask a question (with personality)

    private func askQuestion(app: Application, remaining: Int) async {
        let system = """
            You are \(aiName), playing 20 Questions as the guesser.
            Your personality: \(personality.toneRules)

            \(gameState.promptContext)

            YOUR TASK — ask ONE yes/no question:

            STRATEGY:
            - The secret could be ANYTHING: an object, body part, material, concept,
              natural phenomenon, food, place, animal, feeling — keep an open mind
            - Choose the question that eliminates the MOST remaining possibilities
            - Aim for a question where yes and no are roughly equally likely (~50/50 split)
            - Do NOT ask about anything already in CONFIRMED or RULED OUT above
            - Do NOT repeat any question from the history
            - With ~\(gameState.estimatedCandidates) possibilities remaining and
              \(remaining) questions left, \(remaining <= 8 ? "start narrowing aggressively" : "keep it broad")

            TONE RULES (follow strictly):
            \(personality.toneRules)

            VARIETY RULE: Look at the last 3 questions in the history above.
            Your question MUST start with a different word than all of them.
            If the last question started with "Can", start with something else.
            If the last question started with "Is", start with something else.

            OUTPUT: One yes/no question only. No preamble. No emojis. No explanation.
            """

        do {
            WebSocketManager.shared.sendToAnswerer(in: roomCode, event: .typingIndicator())

            let raw = try await openAI.chat(
                system: system,
                messages: [],
                maxTokens: 35,
                temperature: 0.5
            )

            let question = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")

            let alreadyAsked = gameState.turns.contains {
                $0.question.lowercased() == question.lowercased()
            }
            let finalQuestion = alreadyAsked ? fallbackQuestion() : question

            app.logger.info("🤖 \(aiName) asking: \(finalQuestion)")
            sendAction(GameActionEnvelope.encoded(
                .askQuestion(AskQuestionPayload(question: finalQuestion))
            ), app: app)

        } catch {
            app.logger.error("🤖 Question error: \(error)")
            let fb = fallbackQuestion()
            sendAction(GameActionEnvelope.encoded(
                .askQuestion(AskQuestionPayload(question: fb))
            ), app: app)
        }
    }

    // MARK: - Make a guess

    private func makeGuess(app: Application, remaining: Int) async {
        let system = """
            You are \(aiName), playing 20 Questions. Time to make your best guess.
            Your personality: \(personality.toneRules)

            \(gameState.promptContext)

            YOUR TASK: identify the secret based on EVERYTHING confirmed above.

            RULES:
            - NEVER guess any word from the WRONG GUESSES list
            - The secret must fit ALL confirmed YES answers simultaneously
            - Think about unusual things too — it could be a body part, a material,
              a natural phenomenon, something abstract-but-physical
            - Respond with ONE WORD only. No punctuation. No explanation.
            """

        do {
            WebSocketManager.shared.sendToAnswerer(in: roomCode, event: .typingIndicator())

            let raw = try await openAI.chat(
                system: system,
                messages: [],
                maxTokens: 10,
                temperature: 0.2
            )

            let guess = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .split(separator: " ").first.map(String.init) ?? raw

            guard !gameState.wrongGuesses.contains(guess.lowercased()) else {
                app.logger.warning("🤖 GPT repeated wrong guess '\(guess)' — asking instead")
                await askQuestion(app: app, remaining: remaining)
                return
            }

            app.logger.info("🤖 \(aiName) guessing: \(guess)")
            sendAction(GameActionEnvelope.encoded(
                .makeGuess(MakeGuessPayload(guess: guess))
            ), app: app)

        } catch {
            app.logger.error("🤖 Guess error: \(error)")
        }
    }

    // MARK: - Answer a question (answerer role)

    private func answerQuestion(question: String, app: Application) async {
        guard let secret else { return }

        do {
            WebSocketManager.shared.sendToQuestioner(in: roomCode, event: .typingIndicator())
            try? await Task.sleep(for: .milliseconds(Int(Double.random(in: 0.6...1.6) * 1000)))

            let response = try await openAI.chat(
                system: "You are playing 20 Questions. You know the secret. Answer only Yes or No.",
                messages: [OpenAIClient.Message(role: "user",
                    content: "Secret: \"\(secret)\"\nQuestion: \"\(question)\"\nAnswer Yes or No only.")],
                maxTokens: 5,
                temperature: 0.1
            )

            let isYes = response.lowercased().hasPrefix("yes")
            sendAction(GameActionEnvelope.encoded(
                .answerQuestion(AnswerQuestionPayload(answer: isYes))
            ), app: app)

        } catch {
            sendAction(GameActionEnvelope.encoded(
                .answerQuestion(AnswerQuestionPayload(answer: false))
            ), app: app)
        }
    }

    // MARK: - Generate hint (answerer role)

    private func generateHint(app: Application) async {
        guard let secret,
              let state = WebSocketManager.shared.currentState(for: roomCode) else { return }

        let history = state.questionsAsked
            .compactMap { q -> String? in
                guard let a = q.answer else { return nil }
                return "Q: \(q.question) → \(a)"
            }.joined(separator: "\n")

        do {
            let hint = try await openAI.chat(
                system: "You are playing 20 Questions. Give one subtle indirect clue. Never reveal the category. One sentence.",
                messages: [OpenAIClient.Message(role: "user",
                    content: "Secret: \"\(secret)\"\nHistory:\n\(history)\nGive one subtle hint.")],
                maxTokens: 60
            )
            sendAction(GameActionEnvelope.encoded(
                .provideHint(ProvideHintPayload(hint: hint.trimmingCharacters(in: .whitespacesAndNewlines)))
            ), app: app)
        } catch {
            sendAction(GameActionEnvelope.encoded(
                .provideHint(ProvideHintPayload(hint: "Think about where you'd encounter this in daily life."))
            ), app: app)
        }
    }

    // MARK: - Pick a secret

    private func pickSecret(app: Application) async -> String {
        let categories = [
            "a household appliance", "a sport", "a vehicle", "a musical instrument",
            "a hand tool", "a wild animal", "a type of building", "a board game",
            "a piece of clothing", "a body of water"
        ]
        let category = categories.randomElement()!

        do {
            let r = try await openAI.chat(
                system: "Give ONE well-known single-word example. One word only — no spaces.\nGood: Piano, Telescope, Volcano\nBad: Tennis Ball, Lake Superior",
                messages: [OpenAIClient.Message(role: "user",
                    content: "Single-word example of: \(category)")],
                maxTokens: 10,
                temperature: 0.85
            )
            return r.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").first.map(String.init) ?? r
        } catch {
            return ["Piano", "Volcano", "Submarine", "Telescope", "Bicycle",
                    "Compass", "Lighthouse", "Hammer", "Glacier", "Drumkit"]
                .randomElement() ?? "Piano"
        }
    }

    // MARK: - Send action to WebSocketManager

    nonisolated func sendAction(_ json: String, app: Application) {
        WebSocketManager.shared.handle(
            raw: json, playerID: playerID, roomCode: roomCode, role: role
        )
    }

    // MARK: - Process a hint with dedicated reasoning before next move

    private func processHintAndAct(hint: String, app: Application) async {
        guard let state = WebSocketManager.shared.currentState(for: roomCode) else { return }
        let remaining = state.questionsRemaining

        if gameState.shouldGuessNow(questionsRemaining: remaining) {
            await makeGuess(app: app, remaining: remaining)
            return
        }

        let system = """
            You are playing 20 Questions. You just received a HINT from the answerer.

            HINT: "\(hint)"

            EVERYTHING KNOWN SO FAR:
            \(gameState.promptContext)

            Questions remaining: \(remaining)

            The hint is a HIGH-PRIORITY clue. It likely corrects your current direction.
            
            TASK:
            1. What does this hint strongly imply about the secret? (think: profession, person,
               action, concept, physical object, living thing, abstract idea?)
            2. Based on the hint AND all confirmed/eliminated facts, ask the single most
               targeted yes/no question that will narrow down to the answer fastest.
            
            RULES:
            - Do NOT repeat any question from the history
            - The question must be consistent with ALL confirmed Yes answers
            - If the hint makes the answer obvious, ask a confirming question (e.g. "Is it a doctor?")
            - One question only. No preamble. No emojis.
            """

        do {
            WebSocketManager.shared.sendToAnswerer(in: roomCode, event: .typingIndicator())

            let raw = try await openAI.chat(
                system: system,
                messages: [],
                maxTokens: 35,
                temperature: 0.3
            )

            let question = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")

            let alreadyAsked = gameState.turns.contains {
                $0.question.lowercased() == question.lowercased()
            }

            let finalQuestion = alreadyAsked ? fallbackQuestion() : question
            app.logger.info("🤖 Post-hint question: \(finalQuestion)")

            sendAction(GameActionEnvelope.encoded(
                .askQuestion(AskQuestionPayload(question: finalQuestion))
            ), app: app)

        } catch {
            app.logger.error("🤖 Post-hint question error: \(error)")
            await askQuestion(app: app, remaining: remaining)
        }
    }

    // MARK: - Specific-thing extractor

    nonisolated func extractSpecificThing(from question: String) -> String? {
        let q = question
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "?", with: "")

        let patterns = [
            "is it a ", "is it an ",
            "could it be a ", "could it be an ",
            "is this a ", "is this an ",
            "is the secret a ", "is the secret an ",
            "is it ", "could it be "
        ]

        for pattern in patterns {
            if q.hasPrefix(pattern) {
                let candidate = String(q.dropFirst(pattern.count))
                    .trimmingCharacters(in: .whitespaces)
                let words = candidate.components(separatedBy: " ").filter { !$0.isEmpty }
                guard words.count <= 2 else { continue }
                guard !isCategory(candidate) else { continue }
                return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
        }
        return nil
    }

    private nonisolated func isCategory(_ word: String) -> Bool {
        let categories: Set<String> = [
            "living", "alive", "animal", "mammal", "bird", "fish", "reptile", "insect",
            "plant", "fungus", "object", "thing", "item", "tool", "vehicle", "food",
            "edible", "man-made", "manmade", "natural", "physical", "tangible", "abstract",
            "concept", "idea", "feeling", "emotion", "event", "real", "fictional",
            "larger", "smaller", "bigger", "heavier", "lighter", "older", "newer",
            "indoors", "outdoors", "common", "rare", "expensive", "cheap", "hard", "soft",
            "type", "kind", "sort", "form", "example", "category",
            "person", "human", "people",
            "profession", "job", "career", "occupation",
            "color", "colour", "shape", "size", "texture",
            "something", "anything", "everything"
        ]
        return categories.contains(word) || categories.contains { word.contains($0) }
    }

    // MARK: - Fallback question

    private func fallbackQuestion() -> String {
        if gameState.isPhysicalThing  == nil { return "Can you physically touch it?" }
        if gameState.isLivingOrganism == nil && gameState.isPhysicalThing == true {
            return "Is it alive or was it ever alive?"
        }
        if gameState.isAnimal == nil && gameState.isLivingOrganism == true {
            return "Is it an animal?"
        }
        if gameState.isMammal == nil && gameState.isAnimal == true {
            return "Is it a mammal?"
        }
        if gameState.isManmade == nil && gameState.isLivingOrganism == false {
            return "Did humans create or manufacture it?"
        }
        if gameState.isBodyPart == nil && gameState.isPhysicalThing == true
            && gameState.isLivingOrganism == false {
            return "Is it a part of the human body?"
        }
        if gameState.isLargerThanHand == nil {
            return "Could you fit it in the palm of your hand?"
        }
        return "Is it something most people encounter in their daily life?"
    }

    // MARK: - Names and personalities

    static func randomName() -> String {
        ["Aria", "Nova", "Zeno", "Iris", "Axel",
         "Luna", "Orion", "Sage", "Echo", "Blaze"].randomElement() ?? "Nova"
    }

    static func randomPersonality() -> AIPersonality {
        AIPersonality.all.randomElement() ?? .curiousFriend
    }
}

// MARK: - AI Personality

struct AIPersonality {
    let name:      String
    let toneRules: String

    static let curiousFriend = AIPersonality(
        name: "Curious Friend",
        toneRules: """
            Tone: warm, genuinely interested, natural.
            - Sound like a friend playing this game, not a professor or chatbot
            - Vary your sentence structure every question — never use the same opener twice
            - Occasional light enthusiasm is fine ("Oh interesting!" once, not every turn)
            - NO emojis. NO repeated filler phrases like "Hmm okay okay" or "Alrighty then"
            - Just ask the question cleanly and naturally
            Bad: "Hmm okay okay... is it something you can read? 📚😊"
            Good: "Can you actually read it, like text on a page?"
            Good: "Would you find this in a library?"
            Good: "Is it the kind of thing you'd study from?"
            Each question must start differently from the previous one.
            """
    )

    static let directDetective = AIPersonality(
        name: "Direct Detective",
        toneRules: """
            Tone: sharp, efficient, confident. Like someone who is very good at this game.
            - Ask precisely worded questions with no padding
            - No enthusiasm, no filler, no emojis
            - Occasionally note your reasoning in ONE phrase before the question, but not every time
            - Questions are short and surgical
            Bad: "Hmm, I wonder... is it something that you can use for studying? 🤔📚"
            Good: "Can you read it?"
            Good: "Does it exist in physical form?"
            Good: "Would you find this in most homes?"
            Vary openings — never repeat the same sentence structure twice in a row.
            """
    )

    static let casualPlayer = AIPersonality(
        name: "Casual Player",
        toneRules: """
            Tone: relaxed, conversational, like someone playing casually on their phone.
            - Short sentences. Informal but not trying too hard.
            - No emojis. No repeated verbal tics. No catchphrases.
            - Just ask what you want to know, plainly.
            Bad: "Alrighty then! Is it something that you can use for fun? 🎉😄"
            Good: "Is it something physical you can hold?"
            Good: "Do most people own one of these?"
            Good: "Is it bigger than a shoebox?"
            Mix up your question structure each time — short sometimes, longer others.
            """
    )

    static let all: [AIPersonality] = [.curiousFriend, .directDetective, .casualPlayer]
}

// MARK: - AIEventWrapper

struct AIEventWrapper {
    let type:  String
    let event: AIEvent

    init?(json: String) {
        guard
            let data = json.data(using: .utf8),
            let raw  = try? JSONDecoder().decode(RawEnvelope.self, from: data)
        else { return nil }
        self.type  = raw.type
        self.event = AIEvent(type: raw.type, payload: raw.payload)
    }

    struct RawPayload: Decodable {
        let id:                String?
        let questionNumber:    Int?
        let question:          String?
        let answer:            String?
        let hint:              String?
        let hintsRemaining:    Int?
        let phase:             String?
        let opponentConnected: Bool?
        let secretConfirmed:   Bool?
    }

    private struct RawEnvelope: Decodable {
        let type:    String
        let payload: RawPayload?
    }
}

enum AIEvent {
    case gameStarted
    case questionAsked(id: String, number: Int, question: String)
    case answerGiven(id: String, question: String, answer: String)
    case hintGiven(remaining: Int, answer: String)
    case hintRequested
    case gameWon
    case gameLost
    case opponentLeft
    case opponentJoined
    case stateSnapshot(phase: String, opponentConnected: Bool, secretConfirmed: Bool)
    case other

    init(type: String, payload: AIEventWrapper.RawPayload?) {
        switch type {
        case "gameStarted":    self = .gameStarted
        case "hintRequested":  self = .hintRequested
        case "gameWon":        self = .gameWon
        case "gameLost":       self = .gameLost
        case "opponentLeft":   self = .opponentLeft
        case "opponentJoined": self = .opponentJoined
        case "hintGiven":
            self = .hintGiven(
                remaining: payload?.hintsRemaining ?? 0,
                answer: payload?.hint ?? ""
            )
        case "questionAsked":
            if let id = payload?.id, let n = payload?.questionNumber, let q = payload?.question {
                self = .questionAsked(id: id, number: n, question: q)
            } else { self = .other }
        case "answerGiven":
            if let id = payload?.id, let q = payload?.question, let a = payload?.answer {
                self = .answerGiven(id: id, question: q, answer: a)
            } else { self = .other }
        case "stateSnapshot":
            self = .stateSnapshot(
                phase: payload?.phase ?? "",
                opponentConnected: payload?.opponentConnected ?? false,
                secretConfirmed: payload?.secretConfirmed ?? false
            )
        default:
            self = .other
        }
    }
}

// MARK: - GameActionEnvelope encoded helper
// The AI never sends requestRewardedHint itself (only human players do after watching an ad),
// but the switch must be exhaustive since DecodedPayload now includes that case.

extension GameActionEnvelope {
    static func encoded(_ payload: DecodedPayload) -> String {
        switch payload {
        case .setSecret(let p):
            return #"{"type":"setSecret","payload":{"secret":"\#(p.secret)"}}"#
        case .askQuestion(let p):
            let e = p.question.replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"type":"askQuestion","payload":{"question":"\#(e)"}}"#
        case .answerQuestion(let p):
            return #"{"type":"answerQuestion","payload":{"answer":\#(p.answer)}}"#
        case .makeGuess(let p):
            let e = p.guess.replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"type":"makeGuess","payload":{"guess":"\#(e)"}}"#
        case .requestRestart:      return #"{"type":"requestRestart","payload":{}}"#
        case .confirmRestart:      return #"{"type":"confirmRestart","payload":{}}"#
        case .startGame:           return #"{"type":"startGame","payload":{}}"#
        case .dismissGame:         return #"{"type":"dismissGame","payload":{}}"#
        case .requestHint:         return #"{"type":"requestHint","payload":{}}"#
        case .requestRewardedHint: return #"{"type":"requestRewardedHint","payload":{}}"#
        case .provideHint(let p):
            let e = p.hint.replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"type":"provideHint","payload":{"hint":"\#(e)"}}"#
        }
    }
}
