import Foundation

/// Deterministic, non-destructive musical transformations for an ostinato.
public enum OstinatoVariation: String, CaseIterable, Codable, Sendable {
    case rotate = "Rotate"
    case reverse = "Reverse"
    case octaveUp = "Octave Up"
    case octaveDown = "Octave Down"
    case accent = "Accent"
    case soften = "Soften"
    case sparse = "Sparse"
    case dense = "Dense"
}

public enum OstinatoVariationEngine {
    /// Produces a new editable pattern; never changes the source or its lane routing.
    /// A seed makes density changes repeatable across sessions.
    public static func makeVariation(of source: OstinatoPattern,
                                     kind: OstinatoVariation,
                                     seed: UInt64 = 1) -> OstinatoPattern {
        var result = source
        result.id = UUID()
        result.name = source.name + " — " + kind.rawValue
        let count = source.stepCount
        guard count > 0 else { return result }
        for laneIndex in result.lanes.indices {
            let laneID = result.lanes[laneIndex].id
            var lane = result.lanes[laneIndex]
            switch kind {
            case .rotate:
                for i in lane.steps.indices {
                    lane.steps[i].index = (lane.steps[i].index + 1) % count
                }
            case .reverse:
                for i in lane.steps.indices {
                    lane.steps[i].index = count - 1 - lane.steps[i].index
                }
            case .octaveUp, .octaveDown:
                let shift = kind == .octaveUp ? 12 : -12
                lane.pitch = UInt8(min(127, max(0, Int(lane.pitch) + shift)))
                for i in lane.steps.indices {
                    lane.steps[i].pitch = UInt8(min(127, max(0, Int(lane.steps[i].pitch) + shift)))
                }
            case .accent, .soften:
                for i in lane.steps.indices {
                    let old = Int(lane.steps[i].velocity)
                    lane.steps[i].velocity = UInt8(kind == .accent ?
                        min(127, old + 18) : max(1, old - 18))
                }
            case .sparse:
                lane.steps = lane.steps.filter { step in
                    let key = mix(seed, UInt64(laneIndex), UInt64(max(0, step.index)))
                    return key % 4 != 0
                }
            case .dense:
                let occupied = Set(lane.steps.map(\.index))
                for index in 0..<count where !occupied.contains(index) {
                    if mix(seed, UInt64(laneIndex), UInt64(index)) % 4 == 0 {
                        lane.steps.append(OstinatoStep(index: index, pitch: lane.pitch,
                                                       velocity: 75, gate: 0.7))
                    }
                }
            }
            lane.steps.sort { $0.index < $1.index }
            lane.id = laneID
            result.lanes[laneIndex] = lane
        }
        return result
    }

    /// Stable integer mixing, independent of Swift's randomized Hasher.
    private static func mix(_ seed: UInt64, _ lane: UInt64, _ step: UInt64) -> UInt64 {
        var x = seed &+ lane &* 0x9E3779B97F4A7C15 &+ step &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return x ^ (x >> 31)
    }
}
