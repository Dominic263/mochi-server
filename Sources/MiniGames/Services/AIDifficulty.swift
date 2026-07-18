import Foundation

// MARK: - AIDifficulty
//
// One knob the client can set per AI game ("easy" | "medium" | "hard",
// default medium). Difficulty NEVER makes the AI lie or break rules — it
// tunes how efficiently the AI narrows the space as questioner, and how
// hard its secret word / how revealing its hints are as answerer.

enum AIDifficulty: String, Codable, Sendable {
    case easy
    case medium
    case hard

    // ── Questioner: strategy prompt fragment ──

    var questionStrategy: String {
        switch self {
        case .easy:
            return """
            - You're a casual, slightly distractible player. Prefer fun, concrete
              questions ("Is it fluffy?", "Would I find it at a party?") over
              cold-blooded category halving.
            - It's fine if your question only rules out a small slice of
              possibilities — you play on vibes, not information theory.
            - Never ask about anything already CONFIRMED or RULED OUT above.
            """
        case .medium:
            return """
            - Choose the question that eliminates the MOST remaining possibilities.
            - Aim for a question where yes and no are roughly equally likely (~50/50 split).
            - Do NOT ask about anything already in CONFIRMED or RULED OUT above.
            """
        case .hard:
            return """
            - You are a ruthless optimizer playing perfect 20 Questions.
            - Choose the single question that splits the remaining possibility
              space closest to 50/50 given EVERYTHING known above.
            - Early game: broad category halving (physical? living? man-made?
              bigger than X? found indoors?). Late game: decisive confirmations.
            - Never waste a turn: no redundant questions, nothing implied by
              existing answers, no near-duplicates of history.
            """
        }
    }

    /// Sampling temperature for question generation — higher = scattier.
    var questionTemperature: Double {
        switch self {
        case .easy:   return 0.9
        case .medium: return 0.5
        case .hard:   return 0.3
        }
    }

    /// Sampling temperature for the final guess — higher = sloppier recall.
    var guessTemperature: Double {
        switch self {
        case .easy:   return 0.7
        case .medium: return 0.2
        case .hard:   return 0.1
        }
    }

    /// Whether this tier ever asks the human for hints.
    var usesHints: Bool {
        switch self {
        case .easy:   return false
        case .medium: return true
        case .hard:   return true
        }
    }

    // ── Answerer: secret-word pools ──
    // Easy defends everyday concrete things a kid could guess; hard defends
    // fair-but-unusual words. Medium keeps the GPT category flow.

    var staticSecretPool: [String] {
        switch self {
        case .easy:
            return ["Dog", "Pizza", "Car", "Chair", "Apple", "Ball",
                    "Book", "Shoe", "Cat", "House", "Phone", "Cup",
                    "Banana", "Bed", "Clock", "Fish"]
        case .medium:
            return ["Piano", "Volcano", "Submarine", "Telescope", "Bicycle",
                    "Compass", "Lighthouse", "Hammer", "Glacier", "Drumkit"]
        case .hard:
            return ["Shadow", "Echo", "Magnet", "Avalanche", "Origami",
                    "Hourglass", "Tornado", "Anchor", "Fossil", "Prism",
                    "Quicksand", "Scarecrow", "Stalactite", "Metronome"]
        }
    }

    /// Prompt describing what kind of secret to pick (medium/hard use GPT
    /// with a category; easy always uses the static pool).
    var secretPickInstruction: String? {
        switch self {
        case .easy:
            return nil
        case .medium:
            return "Give ONE well-known single-word example. One word only — no spaces.\nGood: Piano, Telescope, Volcano\nBad: Tennis Ball, Lake Superior"
        case .hard:
            return "Give ONE fair but UNCOMMON single-word example — something most adults know exists but wouldn't guess quickly. One word only — no spaces.\nGood: Stalactite, Metronome, Quicksand\nBad: Dog, Car, obscure jargon nobody knows"
        }
    }

    // ── Answerer: hint style ──

    var hintStyle: String {
        switch self {
        case .easy:
            return "Give one GENEROUS, fairly revealing clue that meaningfully narrows it down (but never say the word itself). One sentence."
        case .medium:
            return "Give one subtle indirect clue. Never reveal the category. One sentence."
        case .hard:
            return "Give one cryptic, oblique clue — evocative but not directly revealing. Never name the category or any close synonym. One sentence."
        }
    }
}
