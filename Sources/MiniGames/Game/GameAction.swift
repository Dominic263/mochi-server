import Foundation

// MARK: - Action types

enum GameActionType: String, Codable {
    case setSecret
    case askQuestion
    case answerQuestion
    case makeGuess
    case requestRestart
    case confirmRestart
    case startGame
    case dismissGame
    case requestHint
    case requestRewardedHint   // client watched a rewarded ad → server grants +1 hint then processes it
    case provideHint
}

// MARK: - Payload types

struct SetSecretPayload: Codable { let secret: String }
struct AskQuestionPayload: Codable { let question: String }
struct AnswerQuestionPayload: Codable { let answer: Bool }
struct MakeGuessPayload: Codable { let guess: String }
struct ProvideHintPayload: Codable { let hint: String }

// MARK: - Envelope

struct GameActionEnvelope: Codable {
    let type: GameActionType
    let payload: DecodedPayload

    enum DecodedPayload {
        case setSecret(SetSecretPayload)
        case askQuestion(AskQuestionPayload)
        case answerQuestion(AnswerQuestionPayload)
        case makeGuess(MakeGuessPayload)
        case requestRestart
        case confirmRestart
        case startGame
        case dismissGame
        case requestHint
        case requestRewardedHint
        case provideHint(ProvideHintPayload)
    }

    enum CodingKeys: String, CodingKey { case type, payload }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(GameActionType.self, forKey: .type)
        self.type = type
        switch type {
        case .setSecret:
            self.payload = .setSecret(try container.decode(SetSecretPayload.self, forKey: .payload))
        case .askQuestion:
            self.payload = .askQuestion(try container.decode(AskQuestionPayload.self, forKey: .payload))
        case .answerQuestion:
            self.payload = .answerQuestion(try container.decode(AnswerQuestionPayload.self, forKey: .payload))
        case .makeGuess:
            self.payload = .makeGuess(try container.decode(MakeGuessPayload.self, forKey: .payload))
        case .requestRestart:
            self.payload = .requestRestart
        case .confirmRestart:
            self.payload = .confirmRestart
        case .startGame:
            self.payload = .startGame
        case .dismissGame:
            self.payload = .dismissGame
        case .requestHint:
            self.payload = .requestHint
        case .requestRewardedHint:
            self.payload = .requestRewardedHint
        case .provideHint:
            self.payload = .provideHint(try container.decode(ProvideHintPayload.self, forKey: .payload))
        }
    }

    func encode(to encoder: any Encoder) throws {}
}
