import Foundation
import DAWCore

/// Run on macOS:
/// swift run -c release RoomAcousticCalibration --seconds 6
/// swift run -c release RoomAcousticCalibration --design-file my-room.json
/// Development-only metrics: no real-room samples or convolution.
struct BandComparison: Codable {
    let centerHz: Double
    let intendedRT60Seconds: Double
    let measuredEDTSeconds: Double?
    let measuredT20Seconds: Double?
    let measuredT30Seconds: Double?
    let t20DifferenceSeconds: Double?
    let t20ErrorPercent: Double?
    let suggestedInputDecaySeconds: Double?
}

struct RoomComparison: Codable {
    let roomID: String
    let roomName: String
    let sampleRate: Double
    let impulseLengthSeconds: Double
    let targetProvenance: String
    let method: String
    let wetOnlyC80dB: Double?
    let bands: [BandComparison]
}

struct Report: Codable {
    let generatedAtISO8601: String
    let profileCount: Int
    let note: String
    let rooms: [RoomComparison]
}

let arguments = Array(CommandLine.arguments.dropFirst())
func argumentValue(_ flag: String, fallback: Double) -> Double {
    guard let index = arguments.firstIndex(of: flag),
          index + 1 < arguments.count,
          let value = Double(arguments[index + 1]), value.isFinite else {
        return fallback
    }
    return value
}

let sampleRate = argumentValue("--sample-rate", fallback: 48_000)
let seconds = argumentValue("--seconds", fallback: 6)
guard (8_000...192_000).contains(sampleRate), (1...20).contains(seconds) else {
    fputs("sample-rate must be 8000...192000 and seconds must be 1...20\n", stderr)
    exit(2)
}

// An optional saved design can be measured without changing Studio's
// running audio engine or the project file itself.
let design: StudioAcousticRoomDesign
if let index = arguments.firstIndex(of: "--design-file") {
    guard index + 1 < arguments.count else {
        fputs("--design-file requires a path to a StudioAcousticRoomDesign JSON file\n", stderr)
        exit(2)
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
        design = try JSONDecoder().decode(StudioAcousticRoomDesign.self, from: data)
    } catch {
        fputs("Could not read room design: \(error)\n", stderr)
        exit(2)
    }
} else {
    design = StudioAcousticRoomDesign()
}

let profiles = StudioRoomAcousticProfile.profiles(with: design)
let results: [RoomComparison] = profiles.map { room in
    let measured = NativeRoomImpulseAnalyzer.measure(
        room: room, sampleRate: sampleRate, seconds: seconds
    )

    // The four factory presets expose three frequency regions, NOT measured
    // octave-band targets. The interpolated values below are only a rough
    // diagnostic target and are explicitly identified as such.
    let targets: [Double]
    let provenance: String
    if let six = room.sixBandRT60, six.count == 6 {
        targets = six.map(Double.init)
        provenance = "Six-band user-design DSP target (0.2–15s bounded), not real-room measurement"
    } else {
        let bass = Double(room.bassRT60)
        let mid = Double(room.midRT60)
        let high = Double(room.trebleRT60)
        targets = [
            bass,
            2 * bass / 3 + mid / 3,
            bass / 3 + 2 * mid / 3,
            mid,
            (mid + high) / 2,
            high
        ]
        provenance = "Three-band factory preset, interpolated for diagnostics only"
    }

    let bands: [BandComparison] = zip(measured.bands, targets).map { measuredBand, target in
        let t20 = measuredBand.t20Seconds
        let proposed: Double?
        if let t20, t20 > 0.1 {
            // First-order offline suggestion, NOT automatically applied:
            // coupled frequency bands and short IR tails require validation.
            proposed = min(15, max(0.2, target * target / t20))
        } else {
            proposed = nil
        }
        return BandComparison(
            centerHz: measuredBand.bandCenterHz,
            intendedRT60Seconds: target,
            measuredEDTSeconds: measuredBand.edtSeconds,
            measuredT20Seconds: t20,
            measuredT30Seconds: measuredBand.t30Seconds,
            t20DifferenceSeconds: t20.map { $0 - target },
            t20ErrorPercent: t20.map { 100 * ($0 - target) / target },
            suggestedInputDecaySeconds: proposed
        )
    }
    return RoomComparison(
        roomID: room.id, roomName: room.name,
        sampleRate: sampleRate, impulseLengthSeconds: seconds,
        targetProvenance: provenance,
        method: "Offline wet-only native early reflections + 16-line FDN; six approximate octave bandpass filters; Schroeder backward energy integration; no room IR reference",
        wetOnlyC80dB: measured.wetOnlyC80dB,
        bands: bands
    )
}

let report = Report(
    generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
    profileCount: results.count,
    note: "Experimental six-band analysis of Studio's own synthesized responses. No venue impulse measurements. T20/T30 may be unavailable for insufficient response length or frequency resolution; filterbanks and finite-tail integration are not ISO 3382 compliant. Suggestions are not applied automatically.",
    rooms: results
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(report)
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data([10]))
