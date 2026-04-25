import Foundation

// MARK: - RoomCodeGenerator
// Generates human-friendly room codes like "WOLF-42".
// Short enough to read aloud or type from a screenshot.

struct RoomCodeGenerator {

    private static let words = [
        "WOLF", "BLUE", "BOLD", "CALM", "DARK",
        "FAST", "GOLD", "GREY", "IRON", "JADE",
        "KEEN", "LIME", "MINT", "NAVY", "OAK",
        "PINE", "ROSE", "RUBY", "SAGE", "TEAL"
    ]

    /// Returns a code like "WOLF-42"
    static func generate() -> String {
        let word   = words.randomElement()!
        let number = Int.random(in: 10...99)
        return "\(word)-\(number)"
    }
}
