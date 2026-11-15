import Foundation

// MARK: - Sound Designer: offline, deterministic language interpretation

/// Interpretation is deliberately separate from patch generation and audio
/// rendering. Milestone 1 never changes a track, launches a model, or makes a
/// network request. Milestone 2 can translate this typed intent to DSP values.
public enum StudioSoundDesignMode: String, Codable, Sendable {
    case create
    case refine
}

public enum StudioSoundQuality: String, Codable, CaseIterable, Sendable {
    case brightness
    case warmth
    case attackTime
    case releaseTime
    case movement
    case metallicCharacter
    case noise
    case lowEnd
    case spaciousness
    case aggression
    case harmonicComplexity
}

public enum StudioSoundInstructionAction: String, Codable, Sendable {
    /// Set an absolute, normalized quality target (0...1).
    case set
    /// Increase/decrease the existing quality by a normalized amount.
    case increase
    case decrease
}

public struct StudioSoundQualityInstruction: Codable, Equatable, Sendable {
    public let quality: StudioSoundQuality
    public let action: StudioSoundInstructionAction
    public let amount: Float
    public let evidence: String

    public init(quality: StudioSoundQuality, action: StudioSoundInstructionAction,
                amount: Float, evidence: String) {
        self.quality = quality
        self.action = action
        self.amount = amount
        self.evidence = evidence
    }
}

public enum StudioSoundRole: String, Codable, CaseIterable, Sendable {
    case pad, lead, bass, keys, pluck, percussion, texture
}

public enum StudioSoundFamily: String, Codable, CaseIterable, Sendable {
    case strings, brass, woodwinds, voice, bells, percussion, noise
}

/// Portable semantic input for a future native patch builder. Engine hints
/// identify ONLY engines the user explicitly named; the synthesizer selector
/// remains free to make its own choices when no engine was requested.
public struct StudioSoundDescriptionIntent: Codable, Equatable, Sendable {
    public let originalText: String
    public let mode: StudioSoundDesignMode
    public let role: StudioSoundRole?
    public let families: [StudioSoundFamily]
    public let excludedFamilies: [StudioSoundFamily]
    public let engineHints: [StudioSynthEngine]
    public let excludedEngines: [StudioSynthEngine]
    public let instructions: [StudioSoundQualityInstruction]
    public let recognizedPhrases: [String]

    public var hasRecognizedIntent: Bool {
        role != nil || !families.isEmpty || !excludedFamilies.isEmpty ||
        !engineHints.isEmpty || !excludedEngines.isEmpty ||
        !instructions.isEmpty
    }

    public func instruction(for quality: StudioSoundQuality)
        -> StudioSoundQualityInstruction? {
        instructions.first { $0.quality == quality }
    }
}

public enum StudioSoundDescriptionError: Error, LocalizedError, Equatable {
    case emptyDescription
    case descriptionTooLong

    public var errorDescription: String? {
        switch self {
        case .emptyDescription:
            return "Describe the sound you want to create."
        case .descriptionTooLong:
            return "Sound descriptions must be 2,000 characters or fewer."
        }
    }
}

/// A bounded, deterministic, Foundation-only interpreter. It recognizes
/// sound qualities, instrument roles, acoustic families, explicit engine
/// requests, negation and relative changes without an LLM or API key.
///
/// This is NOT a patch generator. It produces semantic instructions only.
public enum StudioSoundDescriptionInterpreter {
    public static let maximumCharacters = 2_000

    public static func interpret(
        _ description: String,
        mode: StudioSoundDesignMode = .create
    ) throws -> StudioSoundDescriptionIntent {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StudioSoundDescriptionError.emptyDescription }
        guard text.count <= maximumCharacters else {
            throw StudioSoundDescriptionError.descriptionTooLong
        }

        let tokens = tokenize(text)
        var selected: [StudioSoundQuality: (end: Int, length: Int,
                                           instruction: StudioSoundQualityInstruction)] = [:]
        var role: (position: Int, value: StudioSoundRole)?
        var families: [StudioSoundFamily] = []
        var excludedFamilies: [StudioSoundFamily] = []
        var engines: [StudioSynthEngine] = []
        var excludedEngines: [StudioSynthEngine] = []
        var recognized: [String] = []

        for i in tokens.indices {
            let modifiers = modifiers(before: i, tokens: tokens)
            for rule in qualityRules where matches(rule.words, at: i, tokens: tokens) {
                let polarityHigh = rule.high != (modifiers.negated || modifiers.less)
                let isRelative = mode == .refine || modifiers.more || modifiers.less
                let action: StudioSoundInstructionAction = isRelative
                    ? (polarityHigh ? .increase : .decrease) : .set
                let amount: Float
                if action == .set {
                    amount = polarityHigh
                        ? (modifiers.subtle ? 0.62 : (modifiers.strong ? 0.9 : 0.78))
                        : (modifiers.subtle ? 0.38 : (modifiers.strong ? 0.1 : 0.22))
                } else {
                    amount = modifiers.subtle ? 0.12 : (modifiers.strong ? 0.43 : 0.26)
                }
                let phrase = rule.words.joined(separator: " ")
                let candidate = StudioSoundQualityInstruction(
                    quality: rule.quality, action: action, amount: amount,
                    evidence: phrase)
                let end = i + rule.words.count
                if let previous = selected[rule.quality],
                   previous.end > end ||
                   (previous.end == end && previous.length >= rule.words.count) {
                    continue
                }
                selected[rule.quality] = (end, rule.words.count, candidate)
                appendUnique(phrase, to: &recognized)
            }

            for rule in roleRules where matches(rule.words, at: i, tokens: tokens) {
                if !modifiers.negated {
                    if role == nil || i + rule.words.count >= role!.position {
                        role = (i + rule.words.count, rule.value)
                    }
                }
                appendUnique(rule.words.joined(separator: " "), to: &recognized)
            }

            for rule in familyRules where matches(rule.words, at: i, tokens: tokens) {
                if modifiers.negated {
                    appendUnique(rule.value, to: &excludedFamilies)
                } else {
                    appendUnique(rule.value, to: &families)
                }
                appendUnique(rule.words.joined(separator: " "), to: &recognized)
            }

            for rule in engineRules where matches(rule.words, at: i, tokens: tokens) {
                if modifiers.negated {
                    appendUnique(rule.value, to: &excludedEngines)
                } else {
                    appendUnique(rule.value, to: &engines)
                }
                appendUnique(rule.words.joined(separator: " "), to: &recognized)
            }
        }

        // An explicit exclusion always wins over an earlier generic mention.
        families.removeAll { excludedFamilies.contains($0) }
        engines.removeAll { excludedEngines.contains($0) }
        let ordered = StudioSoundQuality.allCases.compactMap { selected[$0]?.instruction }

        return StudioSoundDescriptionIntent(
            originalText: text, mode: mode, role: role?.value,
            families: families, excludedFamilies: excludedFamilies,
            engineHints: engines, excludedEngines: excludedEngines,
            instructions: ordered, recognizedPhrases: recognized)
    }

    private struct QualityRule: Sendable {
        let words: [String]
        let quality: StudioSoundQuality
        let high: Bool
        init(_ phrase: String, _ quality: StudioSoundQuality, _ high: Bool) {
            words = phrase.split(separator: " ").map(String.init)
            self.quality = quality
            self.high = high
        }
    }

    private struct NamedRule<T: Sendable>: Sendable {
        let words: [String]
        let value: T
        init(_ phrase: String, _ value: T) {
            words = phrase.split(separator: " ").map(String.init)
            self.value = value
        }
    }

    private struct Modifiers {
        var negated = false
        var more = false
        var less = false
        var subtle = false
        var strong = false
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "don't", with: "dont")
            .replacingOccurrences(of: "doesn't", with: "doesnt")
            .replacingOccurrences(of: "isn't", with: "isnt")
            // Punctuation marks separate modifier scope: "slightly warm,
            // with a slow attack" must not make the attack "slight".
            .replacingOccurrences(of: ",", with: " clausebreak ")
            .replacingOccurrences(of: ";", with: " clausebreak ")
            .replacingOccurrences(of: ".", with: " clausebreak ")
            .replacingOccurrences(of: ":", with: " clausebreak ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func matches(_ words: [String], at index: Int,
                                tokens: [String]) -> Bool {
        guard index + words.count <= tokens.count else { return false }
        for offset in words.indices where tokens[index + offset] != words[offset] {
            return false
        }
        return true
    }

    /// Modifiers cannot leak through coordinated descriptions such as
    /// "less metallic and more movement".
    private static func modifiers(before index: Int, tokens: [String]) -> Modifiers {
        var result = Modifiers()
        guard index > 0 else { return result }
        let lower = max(0, index - 4)
        for i in stride(from: index - 1, through: lower, by: -1) {
            let word = tokens[i]
            if ["and", "but", "or", "then", "however", "except", "clausebreak"].contains(word) {
                break
            }
            switch word {
            case "not", "no", "without", "avoid", "never", "dont",
                 "doesnt", "isnt", "non":
                result.negated = true
            case "less", "reduce", "decrease", "lower":
                result.less = true
            case "more", "increase", "boost", "raise":
                result.more = true
            case "slightly", "subtly", "subtle", "little", "gentle",
                 "hint", "touch", "somewhat":
                result.subtle = true
            case "very", "extremely", "much", "strongly", "massively":
                result.strong = true
            default:
                break
            }
        }
        return result
    }

    private static func appendUnique<T: Equatable>(_ item: T, to array: inout [T]) {
        if !array.contains(item) { array.append(item) }
    }

    private static let qualityRules: [QualityRule] = [
        .init("bright", .brightness, true), .init("brighter", .brightness, true),
        .init("brilliant", .brightness, true), .init("crisp", .brightness, true),
        .init("sparkling", .brightness, true),
        .init("dark", .brightness, false), .init("darker", .brightness, false),
        .init("muted", .brightness, false), .init("dull", .brightness, false),
        .init("warm", .warmth, true), .init("warmer", .warmth, true),
        .init("rounded", .warmth, true), .init("rich", .warmth, true),
        .init("cold", .warmth, false), .init("icy", .warmth, false),
        .init("thin", .warmth, false),
        .init("slow attack", .attackTime, true),
        .init("slower attack", .attackTime, true),
        .init("soft attack", .attackTime, true),
        .init("gentle onset", .attackTime, true),
        .init("slow swell", .attackTime, true),
        .init("fade in", .attackTime, true),
        .init("fast attack", .attackTime, false),
        .init("quick attack", .attackTime, false),
        .init("sharp attack", .attackTime, false),
        .init("instant attack", .attackTime, false),
        .init("long release", .releaseTime, true),
        .init("long tail", .releaseTime, true),
        .init("lingering tail", .releaseTime, true),
        .init("slow release", .releaseTime, true),
        .init("short release", .releaseTime, false),
        .init("short tail", .releaseTime, false),
        .init("tight release", .releaseTime, false),
        .init("staccato", .releaseTime, false),
        .init("gradually emerge", .movement, true),
        .init("slowly evolving", .movement, true),
        .init("evolving", .movement, true), .init("movement", .movement, true),
        .init("motion", .movement, true), .init("swirling", .movement, true),
        .init("pulsing", .movement, true), .init("animated", .movement, true),
        .init("static", .movement, false), .init("still", .movement, false),
        .init("steady", .movement, false),
        .init("metallic", .metallicCharacter, true),
        .init("metal", .metallicCharacter, true),
        .init("glassy", .metallicCharacter, true),
        .init("bell like", .metallicCharacter, true),
        .init("organic", .metallicCharacter, false),
        .init("wooden", .metallicCharacter, false),
        .init("noisy", .noise, true), .init("noise", .noise, true),
        .init("hissy", .noise, true), .init("airy", .noise, true),
        .init("clean", .noise, false), .init("pure", .noise, false),
        .init("low frequencies", .lowEnd, true),
        .init("low end", .lowEnd, true), .init("deep", .lowEnd, true),
        .init("sub", .lowEnd, true), .init("heavy bass", .lowEnd, true),
        .init("boomy", .lowEnd, true),
        .init("lightweight", .lowEnd, false),
        .init("spacious", .spaciousness, true),
        .init("wide", .spaciousness, true),
        .init("reverberant", .spaciousness, true),
        .init("reverb", .spaciousness, true),
        .init("distant", .spaciousness, true),
        .init("intimate", .spaciousness, false),
        .init("dry", .spaciousness, false),
        .init("close", .spaciousness, false),
        .init("narrow", .spaciousness, false),
        .init("aggressive", .aggression, true),
        .init("gritty", .aggression, true),
        .init("distorted", .aggression, true),
        .init("harsh", .aggression, true),
        .init("gentle", .aggression, false),
        .init("smooth", .aggression, false),
        .init("soft", .aggression, false),
        .init("harmonics", .harmonicComplexity, true),
        .init("shimmer", .harmonicComplexity, true),
        .init("shimmering", .harmonicComplexity, true),
        .init("complex", .harmonicComplexity, true),
        .init("simple", .harmonicComplexity, false),
        .init("sine", .harmonicComplexity, false)
    ]

    private static let roleRules: [NamedRule<StudioSoundRole>] = [
        .init("pad", .pad), .init("pads", .pad),
        .init("lead", .lead), .init("solo", .lead),
        .init("bass", .bass), .init("keys", .keys),
        .init("keyboard", .keys), .init("piano", .keys),
        .init("pluck", .pluck), .init("plucked", .pluck),
        .init("drum", .percussion), .init("drums", .percussion),
        .init("percussion", .percussion),
        .init("texture", .texture), .init("soundscape", .texture)
    ]

    private static let familyRules: [NamedRule<StudioSoundFamily>] = [
        .init("string", .strings), .init("strings", .strings),
        .init("violin", .strings), .init("cello", .strings),
        .init("brass", .brass), .init("horn", .brass),
        .init("trumpet", .brass),
        .init("woodwind", .woodwinds), .init("woodwinds", .woodwinds),
        .init("flute", .woodwinds), .init("clarinet", .woodwinds),
        .init("oboe", .woodwinds), .init("reed", .woodwinds),
        .init("choir", .voice), .init("vocal", .voice),
        .init("voice", .voice),
        .init("bell", .bells), .init("bells", .bells),
        .init("chime", .bells), .init("chimes", .bells),
        .init("drum", .percussion), .init("drums", .percussion),
        .init("percussion", .percussion),
        .init("noise", .noise), .init("noisy", .noise)
    ]

    private static let engineRules: [NamedRule<StudioSynthEngine>] = [
        .init("analog", .analog), .init("analogue", .analog),
        .init("subtractive", .analog),
        .init("fm", .fm), .init("frequency modulation", .fm),
        .init("wavetable", .wavetable),
        .init("additive", .additive),
        .init("granular", .granular), .init("grains", .granular),
        .init("physical modeling", .physical),
        .init("physical model", .physical)
    ]
}
