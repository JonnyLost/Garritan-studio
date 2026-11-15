import Foundation

/// Offline musical development over consecutive repetitions.
/// The source pattern is never mutated; output remains ordinary editable MIDI.
public enum OstinatoEvolutionShape: String, CaseIterable, Codable, Sendable {
    case build = "Build"
    case release = "Release"
    case wave = "Wave"
}

public enum OstinatoEvolutionEngine {
    public static func sequence(from source: OstinatoPattern,
                                repetitions: Int,
                                shape: OstinatoEvolutionShape,
                                seed: UInt64 = 1) -> [OstinatoPattern] {
        let count = min(64, max(1, repetitions))
        return (0..<count).map { iteration in
            let progress = count == 1 ? 0.0 : Double(iteration) / Double(count - 1)
            let intensity: Double
            switch shape {
            case .build: intensity = progress
            case .release: intensity = 1 - progress
            case .wave: intensity = 0.5 - 0.5 * cos(2 * Double.pi * progress)
            }
            var evolved = source
            evolved.id = UUID()
            evolved.name = source.name + " — " + shape.rawValue + " " + String(iteration + 1)
            for laneIndex in evolved.lanes.indices {
                var lane = evolved.lanes[laneIndex]
                let originalSteps = lane.steps
                var occupied = Set(originalSteps.map(\.index))
                lane.steps = originalSteps.filter { step in
                    // Preserve structural downbeats; vary secondary notes predictably.
                    guard step.index % max(1, source.stepsPerBeat) != 0 else { return true }
                    let probability = 0.35 + 0.65 * intensity
                    return fraction(seed, laneIndex, step.index, iteration) < probability
                }
                for stepIndex in 0..<source.stepCount where !occupied.contains(stepIndex) {
                    // Add restrained subdivisions as the pattern builds.
                    if fraction(seed &+ 17, laneIndex, stepIndex, iteration) < 0.16 * intensity {
                        lane.steps.append(OstinatoStep(index: stepIndex, pitch: lane.pitch,
                                                       velocity: 55, gate: 0.65))
                        occupied.insert(stepIndex)
                    }
                }
                for index in lane.steps.indices {
                    let originalVelocity = Int(lane.steps[index].velocity)
                    lane.steps[index].velocity = UInt8(min(127, max(1,
                        Int((Double(originalVelocity) * (0.65 + 0.45 * intensity)).rounded()))))
                }
                lane.steps.sort { $0.index < $1.index }
                evolved.lanes[laneIndex] = lane
            }
            return evolved
        }
    }

    private static func fraction(_ seed: UInt64, _ lane: Int,
                                 _ step: Int, _ iteration: Int) -> Double {
        var x = seed &+ UInt64(lane) &* 0x9E3779B97F4A7C15
        x = x &+ UInt64(step) &* 0xBF58476D1CE4E5B9
        x = x &+ UInt64(iteration) &* 0x94D049BB133111EB
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }
}
