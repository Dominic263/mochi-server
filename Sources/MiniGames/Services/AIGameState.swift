import Foundation

// MARK: - AIGameState
//
// Tracks what the AI knows after each answer — updated deterministically
// in Swift, never by GPT. GPT only generates natural language questions.
//
// Design principle: track FACTS, not a rigid taxonomy path.
// The secret could be anything — a nail, a shadow, a feeling, a country.
// We record what's been confirmed and ruled out, estimate how many things
// could still fit, and let GPT reason freely about what to ask next.

struct AIGameState {

    // MARK: - Turn record

    struct Turn {
        let number:   Int
        let question: String
        let answer:   String
        let wasGuess: Bool
    }
    var turns: [Turn] = []

    // MARK: - Derived knowledge

    var confirmedTraits:  [String] = []
    var eliminatedTraits: [String] = []
    var wrongGuesses:     [String] = []
    var hintsReceived:    [String] = []

    // MARK: - Broad category flags (optional — only set when clearly answered)
    // NOT a mandatory path. Many secrets (nail, shadow, wifi) don't fit neatly.

    var isPhysicalThing:  Bool? = nil
    var specificThingConfirmed: Bool = false   // set when "Is it a X?" → Yes
    var isLivingOrganism: Bool? = nil
    var isAnimal:         Bool? = nil
    var isMammal:         Bool? = nil
    var isManmade:        Bool? = nil
    var isNaturalObject:  Bool? = nil
    var isBodyPart:       Bool? = nil
    var isFood:           Bool? = nil
    var isLargerThanHand: Bool? = nil
    var isLargerThanCar:  Bool? = nil
    var foundIndoors:     Bool? = nil

    // MARK: - Record a new answer

    mutating func record(question: String, answer: String) {
        let isYes    = answer == "Yes"
        let isNo     = answer == "No"
        let wasGuess = question.lowercased().hasPrefix("guess:")

        turns.append(Turn(
            number:   turns.count + 1,
            question: question,
            answer:   answer,
            wasGuess: wasGuess
        ))

        if wasGuess {
            let word = String(question.dropFirst(7))
                .trimmingCharacters(in: .whitespaces).lowercased()
            if !wrongGuesses.contains(word) { wrongGuesses.append(word) }
            return
        }

        guard isYes || isNo else { return }

        if isYes { confirmedTraits.append(question) }
        if isNo  { eliminatedTraits.append(question) }

        let q = question.lowercased()

        if matches(q, ["tangible", "physical thing", "touch it", "hold it", "solid object"]) {
            isPhysicalThing = isYes
        }
        if matches(q, ["concept", "abstract", "idea", "feeling", "emotion", "invisible"]) {
            isPhysicalThing = !isYes
        }
        if matches(q, ["living", "alive", "living organism", "living thing"]) {
            isLivingOrganism = isYes
        }
        if matches(q, ["animal", "creature", "beast"]) {
            isAnimal = isYes
            if isYes { isLivingOrganism = true }
        }
        if matches(q, ["mammal"]) {
            isMammal = isYes
            if isYes { isAnimal = true; isLivingOrganism = true }
        }
        if matches(q, ["man-made", "manmade", "manufactured", "built by", "created by humans"]) {
            isManmade = isYes
        }
        if matches(q, ["found in nature", "natural object", "occurs naturally"]) {
            isNaturalObject = isYes
            if isYes { isManmade = false }
        }
        if matches(q, ["body part", "part of the body", "part of a body", "anatomy"]) {
            isBodyPart = isYes
            if isYes { isPhysicalThing = true }
        }
        if matches(q, ["edible", "food", "eat it", "something you eat"]) {
            isFood = isYes
        }
        if matches(q, ["fit in your hand", "smaller than your hand"]) {
            isLargerThanHand = !isYes
        }
        if matches(q, ["larger than a hand", "bigger than a hand"]) {
            isLargerThanHand = isYes
        }
        if matches(q, ["larger than a car", "bigger than a car"]) {
            isLargerThanCar = isYes
        }
        if matches(q, ["found indoors", "inside a home", "indoors"]) {
            foundIndoors = isYes
        }

        // If this was a specific-thing question that got Yes, we know the answer —
        // collapse the candidate count so shouldGuessNow fires immediately
        if isYes && isSpecificThingQuestion(q) {
            specificThingConfirmed = true
        }
    }

    private func isSpecificThingQuestion(_ q: String) -> Bool {
        // Category/property words — these are NOT specific things
        let broadWords = ["living", "animal", "mammal", "object", "thing", "physical",
                          "tangible", "manmade", "man-made", "natural", "abstract",
                          "larger", "smaller", "edible", "food", "profession", "person",
                          "human", "type", "kind", "something", "anything", "color",
                          "colour", "pattern", "decoration", "warm", "soft", "hard",
                          "used", "found", "made", "come", "have", "read", "hold", "touch"]
        if broadWords.contains(where: { q.contains($0) }) { return false }

        let prefixes = ["is it a ", "is it an ", "could it be a ", "could it be an ",
                        "is this a ", "is this an "]
        for prefix in prefixes {
            if q.hasPrefix(prefix) {
                let candidate = String(q.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                let words = candidate.components(separatedBy: " ").filter { !$0.isEmpty }
                // 1–2 word specific noun = specific thing
                return words.count <= 2
            }
        }
        return false
    }

    mutating func recordHint(_ hint: String) {
        hintsReceived.append(hint)
    }

    // MARK: - Estimated remaining candidates

    var estimatedCandidates: Int {
        var n = 20_000

        if isPhysicalThing == false  { n = min(n, 2_000)  }
        if isPhysicalThing == true   { n = min(n, 15_000) }
        if isLivingOrganism == false { n = min(n, 10_000) }
        if isLivingOrganism == true  { n = min(n, 6_000)  }
        if isAnimal == true          { n = min(n, 1_500)  }
        if isAnimal == false && isLivingOrganism == true { n = min(n, 800) }
        if isMammal == true          { n = min(n, 250)    }
        if isManmade == true         { n = min(n, 5_000)  }
        if isNaturalObject == true   { n = min(n, 3_000)  }
        if isBodyPart == true        { n = min(n, 50)     }
        if isFood == true            { n = min(n, 200)    }
        if isLargerThanCar == true   { n = min(n, 80)     }
        if isLargerThanCar == false  { n = min(n, n * 3 / 4) }
        if isLargerThanHand == false { n = min(n, n / 3)  }
        if foundIndoors == true      { n = min(n, n * 2 / 3) }

        // Each confirmed trait beyond the broad flags halves the space
        let extraConfirmed = max(0, confirmedTraits.count - broadFlagCount)
        for _ in 0..<min(extraConfirmed, 8) { n = max(1, n / 2) }

        // Semantic clustering: when multiple specific-use traits align,
        // collapse the estimate aggressively — we're clearly close to one answer
        let allConfirmed = confirmedTraits.map { $0.lowercased() }

        let readableClues  = allConfirmed.filter { $0.contains("read") || $0.contains("library") || $0.contains("study") || $0.contains("written") || $0.contains("pages") }
        let gameClues      = allConfirmed.filter { $0.contains("game") || $0.contains("play") || $0.contains("board") || $0.contains("sport") }
        let kitchenClues   = allConfirmed.filter { $0.contains("cook") || $0.contains("kitchen") || $0.contains("food") || $0.contains("eat") }
        let musicClues     = allConfirmed.filter { $0.contains("music") || $0.contains("sound") || $0.contains("instrument") || $0.contains("sing") }
        let vehicleClues   = allConfirmed.filter { $0.contains("drive") || $0.contains("vehicle") || $0.contains("wheel") || $0.contains("road") }
        let toolClues      = allConfirmed.filter { $0.contains("tool") || $0.contains("hammer") || $0.contains("build") || $0.contains("fix") || $0.contains("repair") }

        if readableClues.count >= 2  { n = min(n, 8)  }
        if readableClues.count >= 3  { n = min(n, 3)  }
        if gameClues.count >= 2      { n = min(n, 15) }
        if gameClues.count >= 3      { n = min(n, 5)  }
        if kitchenClues.count >= 2   { n = min(n, 15) }
        if musicClues.count >= 2     { n = min(n, 10) }
        if vehicleClues.count >= 2   { n = min(n, 10) }
        if toolClues.count >= 2      { n = min(n, 12) }

        return max(1, n)
    }

    private var broadFlagCount: Int {
        [isPhysicalThing, isLivingOrganism, isAnimal, isMammal,
         isManmade, isNaturalObject, isBodyPart, isFood,
         isLargerThanHand, isLargerThanCar, foundIndoors]
            .compactMap { $0 }.count
    }

    // MARK: - Decision helpers

    func shouldGuessNow(questionsRemaining: Int) -> Bool {
        // Specific thing confirmed — guess immediately regardless of anything else
        if specificThingConfirmed { return true }
        if questionsRemaining <= 2 { return true }
        if estimatedCandidates <= 2 { return true }
        if questionsRemaining <= 5 && estimatedCandidates <= 5 { return true }
        if estimatedCandidates <= 8 && confirmedTraits.count >= 4 { return true }
        if !hintsReceived.isEmpty && estimatedCandidates <= 15 { return true }
        return false
    }

    func shouldRequestHint(questionsRemaining: Int) -> Bool {
        let used = 20 - questionsRemaining
        guard hintsReceived.count < 2 else { return false }
        if used >= 10 && hintsReceived.isEmpty && estimatedCandidates > 30 { return true }
        if used >= 15 && hintsReceived.count == 1 && estimatedCandidates > 10 { return true }
        return false
    }

    // MARK: - Prompt context block

    var promptContext: String {
        var lines: [String] = []

        lines.append("CONFIRMED (answered YES):")
        confirmedTraits.isEmpty
            ? lines.append("  nothing confirmed yet")
            : confirmedTraits.forEach { lines.append("  ✓ \($0)") }

        lines.append("\nRULED OUT (answered NO):")
        eliminatedTraits.isEmpty
            ? lines.append("  nothing ruled out yet")
            : eliminatedTraits.forEach { lines.append("  ✗ \($0)") }

        lines.append("\nWRONG GUESSES — never repeat:")
        lines.append(wrongGuesses.isEmpty ? "  none" : "  " + wrongGuesses.joined(separator: ", "))

        if !hintsReceived.isEmpty {
            lines.append("\nHINTS RECEIVED:")
            hintsReceived.enumerated().forEach { i, h in lines.append("  Hint \(i+1): \(h)") }
        }

        lines.append("\nWHAT WE KNOW:")
        var known: [String] = []
        if let v = isPhysicalThing   { known.append("physical/tangible: \(v ? "YES" : "NO")") }
        if let v = isLivingOrganism  { known.append("living organism: \(v ? "YES" : "NO")") }
        if let v = isAnimal          { known.append("animal: \(v ? "YES" : "NO")") }
        if let v = isMammal          { known.append("mammal: \(v ? "YES" : "NO")") }
        if let v = isManmade         { known.append("man-made: \(v ? "YES" : "NO")") }
        if let v = isNaturalObject   { known.append("natural object: \(v ? "YES" : "NO")") }
        if let v = isBodyPart        { known.append("body part: \(v ? "YES" : "NO")") }
        if let v = isFood            { known.append("edible: \(v ? "YES" : "NO")") }
        if let v = isLargerThanHand  { known.append("larger than a hand: \(v ? "YES" : "NO")") }
        if let v = isLargerThanCar   { known.append("larger than a car: \(v ? "YES" : "NO")") }
        if let v = foundIndoors      { known.append("found indoors: \(v ? "YES" : "NO")") }
        known.isEmpty
            ? lines.append("  nothing yet — the secret could be anything")
            : known.forEach { lines.append("  • \($0)") }

        lines.append("\nESTIMATED REMAINING POSSIBILITIES: ~\(estimatedCandidates)")

        lines.append("\nFULL Q&A HISTORY:")
        turns.isEmpty
            ? lines.append("  no questions asked yet")
            : turns.forEach { t in
                let label = t.wasGuess ? "GUESS" : "Q\(t.number)"
                lines.append("  \(label): \(t.question) → \(t.answer)")
              }

        return lines.joined(separator: "\n")
    }

    private func matches(_ query: String, _ keywords: [String]) -> Bool {
        keywords.contains { query.contains($0) }
    }
}
