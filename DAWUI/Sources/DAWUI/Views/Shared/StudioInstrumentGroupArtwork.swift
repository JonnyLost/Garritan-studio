import Foundation

/// Artwork classification for groups of players and mixed instrument patches.
///
/// This is intentionally separate from patch playback: it never changes the
/// instrument loaded, its keyswitches, or its audio/MIDI routing.
///
/// A nil result means "no confidently recognized ensemble" and allows the
/// individual-instrument resolver to continue working.
enum StudioInstrumentGroupArtwork: String, CaseIterable, Equatable {
    case violins, violas, cellos, basses
    case highStrings, lowStrings, strings
    case flutes, oboes, englishHorns, clarinets, bassoons, saxophones
    case highWoodwinds, lowWoodwinds, woodwinds
    case horns, trumpets, trombones, highBrass, lowBrass, brass
    case percussion, tunedPercussion, auxiliaryPercussion, drumline
    case guitarSection, rhythmSection, worldPercussion, concertBand, marchingBand
    case piccolos, cornets, flugelhorns, mellophones, tenorHorns
    case euphoniums, baritoneHorns, tubas, sousaphones, helicons
    case jazzBigBand, worldEnsemble
    case stringsAndWinds, stringsAndBrass, windsAndBrass, orchestraAndChoir
    case choir, orchestra, mixedEnsemble

    var accessibilityLabel: String {
        switch self {
        case .violins: return "Violin section"
        case .violas: return "Viola section"
        case .cellos: return "Cello section"
        case .basses: return "Double bass section"
        case .highStrings: return "High strings section"
        case .lowStrings: return "Low strings section"
        case .strings: return "String orchestra"
        case .flutes: return "Flute section"
        case .oboes: return "Oboe section"
        case .englishHorns: return "English horn section"
        case .bassoons: return "Bassoon section"
        case .highWoodwinds: return "High woodwind ensemble"
        case .lowWoodwinds: return "Low woodwind ensemble"
        case .clarinets: return "Clarinet section"
        case .saxophones: return "Saxophone section"
        case .woodwinds: return "Woodwind ensemble"
        case .horns: return "Horn section"
        case .trumpets: return "Trumpet section"
        case .trombones: return "Trombone section"
        case .highBrass: return "High brass ensemble"
        case .lowBrass: return "Low brass ensemble"
        case .brass: return "Brass ensemble"
        case .percussion: return "Percussion ensemble"
        case .tunedPercussion: return "Tuned percussion ensemble"
        case .auxiliaryPercussion: return "Auxiliary percussion ensemble"
        case .drumline: return "Marching percussion section"
        case .guitarSection: return "Guitar section"
        case .rhythmSection: return "Rhythm section"
        case .worldPercussion: return "World percussion ensemble"
        case .concertBand: return "Concert band"
        case .marchingBand: return "Marching band"
        case .piccolos: return "Piccolo section"
        case .cornets: return "Cornet section"
        case .flugelhorns: return "Flugelhorn section"
        case .mellophones: return "Mellophone section"
        case .tenorHorns: return "Tenor horn section"
        case .euphoniums: return "Euphonium section"
        case .baritoneHorns: return "Baritone horn section"
        case .tubas: return "Tuba section"
        case .sousaphones: return "Sousaphone section"
        case .helicons: return "Helicon section"
        case .jazzBigBand: return "Jazz big band"
        case .worldEnsemble: return "World instrument ensemble"
        case .stringsAndWinds: return "Strings and woodwinds ensemble"
        case .stringsAndBrass: return "Strings and brass ensemble"
        case .windsAndBrass: return "Woodwinds and brass ensemble"
        case .orchestraAndChoir: return "Orchestra and choir ensemble"
        case .choir: return "Choir section"
        case .orchestra: return "Full orchestra"
        case .mixedEnsemble: return "Mixed orchestral ensemble"
        }
    }

    /// Uses only explicit ensemble wording or unambiguous instrument plurals.
    /// Library metadata is not sufficient to infer unknown Instant Orchestra
    /// combinations; those retain the existing family/unknown illustration.
    static func resolve(name: String, path: String = "", category: String = "") -> Self? {
        let n = name.lowercased()
        if n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        func has(_ terms: [String]) -> Bool {
            terms.contains { n.contains($0) }
        }

        // Names of section/ensemble programs appearing in published Garritan
        // Jazz & Big Band, Concert & Marching Band and World catalogs.
        // These group images are representative, never exact layer metadata.
        if has(["japanese taiko ensemble", "ewe drumming ensemble", "djembe drumming ensemble", "gamelan bali orchestra", "gamelan java orchestra"]) { return .worldPercussion }
        if has(["african orchestra", "chinese orchestra", "global village", "middle east takht", "indian hindustani ensemble", "indian carnatic ensemble", "japanese traditional", "celtic consort", "andean highlands ensemble"]) { return .worldEnsemble }
        if has(["big band #", "full big band", "big band ensemble"]) { return .jazzBigBand }
        if has(["orchestra and choir", "orchestra octaves and choir", "lush orchestra octaves and choir", "orchestra and chorus"]) { return .orchestraAndChoir }
        if has(["strings and winds", "strings & winds", "strings winds", "strings and woodwinds"]) { return .stringsAndWinds }
        if has(["strings and brass", "strings & brass"]) { return .stringsAndBrass }
        if has(["winds and brass", "brass and winds", "winds & brass", "brass & winds"]) { return .windsAndBrass }
        if has(["piccolo group", "piccolo section", "piccolos"]) { return .piccolos }
        if has(["cornet group", "cornet section", "cornets"]) { return .cornets }
        if has(["flugelhorn group", "flugelhorn section", "flugelhorns"]) { return .flugelhorns }
        if has(["mellophone group", "mellophone section", "mellophones"]) { return .mellophones }
        if has(["tenor horn group", "tenor horn section", "tenor horns"]) { return .tenorHorns }
        if has(["euphonium group", "euphonium section", "euphoniums"]) { return .euphoniums }
        if has(["baritone group", "baritone horn section", "baritone horns"]) { return .baritoneHorns }
        if has(["sousaphone group", "sousaphone section", "sousaphones"]) { return .sousaphones }
        if has(["helicon group", "helicon section", "helicons"]) { return .helicons }
        if has(["tuba group", "tuba section", "tubas"]) { return .tubas }

        // Explicit band/ensemble identities. These are schematic group
        // artwork, not claims about any patch's exact orchestration.
        if has(["world percussion ensemble", "world percussion section",
                "ethnic percussion ensemble"]) { return .worldPercussion }
        if has(["guitar section", "guitar ensemble", "guitars ensemble",
                "guitar choir"]) { return .guitarSection }
        if has(["rhythm section", "jazz rhythm ensemble"]) { return .rhythmSection }
        if has(["marching band", "parade band"]) { return .marchingBand }
        if has(["concert band", "symphonic band", "wind symphony"]) { return .concertBand }

        // Broad cross-family groups must win before matching a single member.
        if has(["full orchestra", "orchestra tutti", "orchestral tutti",
                "unison orchestra", "entire orchestra", "whole orchestra",
                "symphony orchestra", "orchestral ensemble", "orchestra section"]) {
            return .orchestra
        }
        if has(["high strings", "upper strings", "violins and violas"]) { return .highStrings }
        if has(["low strings", "lower strings", "cellos and basses",
                "cello and bass", "celli and bass"]) { return .lowStrings }
        if has(["full strings", "string ensemble", "string orchestra",
                "string section", "all strings", "tutti strings",
                "short strings", "symphonic strings"]) { return .strings }

        if has(["high brass", "upper brass"]) { return .highBrass }
        if has(["low brass", "lower brass"]) { return .lowBrass }
        if has(["brass section", "brass ensemble", "full brass", "brass tutti",
                "all brass", "brass choir"]) { return .brass }

        if has(["high winds", "high woodwinds", "upper woodwinds"]) { return .highWoodwinds }
        if has(["low winds", "low woodwinds", "lower woodwinds"]) { return .lowWoodwinds }
        if has(["woodwind section", "woodwind ensemble", "wind ensemble",
                "full woodwinds", "all woodwinds", "winds tutti",
                "high winds", "low winds", "mixed woodwinds"]) { return .woodwinds }
        if has(["tuned percussion", "mallet section", "mallet ensemble",
                "pit percussion section"]) { return .tunedPercussion }
        if has(["auxiliary percussion", "percussion accessories",
                "accessory percussion section"]) { return .auxiliaryPercussion }
        if has(["drumline", "drum line", "marching battery",
                "marching percussion", "tenor drum section"]) { return .drumline }
        if has(["percussion section", "percussion ensemble",
                "percussion accessories", "full percussion",
                "orchestral percussion", "marching percussion"]) { return .percussion }
        if has(["full choir", "choir section", "choir ensemble", "mixed choir",
                "children choir", "boys choir", "women's choir", "men's choir"]) { return .choir }

        // Some Instant Orchestra programs are recognizable only as broad
        // layers, not as exact instrumentation. Do not invent their contents.
        if has(["orchestral layers", "orchestra layers", "orchestral combination",
                "orchestral combo", "orchestra combo", "mixed orchestra",
                "cinematic ensemble"]) {
            return .mixedEnsemble
        }

        // Protect solo/player patches from misleading numbers and folder names.
        let explicitGroup = has([" section", " ensemble", " group", " grp",
                                  " tutti", " unison", " players", " desks",
                                  " soli", " stacked", " layered"])
        let solo = has([" solo", " plr", " player ", " soloist"])
        if solo && !explicitGroup { return nil }

        // Section plural and named-section recognition.
        if has(["violins", "violin section", "violin ensemble"]) { return .violins }
        if has(["violas", "viola section", "viola ensemble"]) { return .violas }
        if has(["cellos", "celli", "cello section", "cello ensemble"]) { return .cellos }
        if has(["double basses", "basses", "bass section", "bass ensemble"]) &&
           !has(["bass clarinet", "bass flute", "bass sax", "bass trombone",
                 "bass drum", "bassoon", "bass brass"]) { return .basses }

        if has(["flutes", "flute section", "flute ensemble"]) { return .flutes }
        if has(["english horns", "english horn section", "english horn ensemble",
                "cor anglais section"]) { return .englishHorns }
        if has(["oboes", "oboe section", "oboe ensemble"]) { return .oboes }
        if has(["bassoons", "bassoon section", "bassoon ensemble"]) { return .bassoons }
        if has(["clarinets", "clarinet section", "clarinet ensemble"]) { return .clarinets }
        if has(["saxophones", "saxes", "sax section", "saxophone section",
                "sax ensemble"]) { return .saxophones }
        if has(["horns", "horn section", "horn ensemble", "french horn section",
                "sam french horn section"]) { return .horns }
        if has(["trumpets", "trumpet section", "trumpet ensemble"]) { return .trumpets }
        if has(["trombones", "trombone section", "trombone ensemble"]) { return .trombones }

        // A section signal with singular naming, e.g. "3 Violin Players".
        // Don't classify unrelated solo sounds that happen to contain a family word.
        if explicitGroup {
            if has(["violin"]) { return .violins }
            if has(["viola"]) { return .violas }
            if has(["cello", "violoncello"]) { return .cellos }
            if has(["double bass", "contrabass"]) { return .basses }
            if has(["flute"]) { return .flutes }
            if has(["english horn", "cor anglais"]) { return .englishHorns }
            if has(["oboe"]) { return .oboes }
            if has(["bassoon"]) { return .bassoons }
            if has(["clarinet"]) { return .clarinets }
            if has(["sax"]) { return .saxophones }
            if has(["french horn", "horn"]) { return .horns }
            if has(["trumpet"]) { return .trumpets }
            if has(["trombone"]) { return .trombones }
            if has(["woodwind", "winds"]) { return .woodwinds }
            if has(["percussion", "drum"]) { return .percussion }
            if has(["brass"]) { return .brass }
            if has(["strings"]) { return .strings }
            if has(["orchestra", "orchestral"]) { return .orchestra }
        }
        return nil
    }
}
