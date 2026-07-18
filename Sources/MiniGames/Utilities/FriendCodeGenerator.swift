import Foundation

// MARK: - FriendCodeGenerator
// Generates 6-character friend codes like "K7PM3X".
// Uppercase letters + digits from an unambiguous set — no 0/O or 1/I — so
// codes survive being read aloud or typed from a screenshot.

struct FriendCodeGenerator {

    /// 32 unambiguous characters → 32^6 ≈ 1.07 billion possible codes.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Returns a code like "K7PM3X". Uniqueness is NOT guaranteed here —
    /// callers must check for collisions (and retry) before saving.
    static func generate() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }
}
