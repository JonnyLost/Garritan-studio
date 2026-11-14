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
    let legacyWideBandT20Seconds: Double?
    let legacyWideBandT20ErrorPercent: Double?
    let uncalibratedT20Seconds: Double?
    let uncalibratedT20ErrorPercent: Double?
    let measuredT30Seconds: Double?
    let t20DifferenceSeconds: Double?
    let t20ErrorPercent: Double?
    let suggestedInputDecaySeconds: Double?
    /// Raw Eyring/Sabine estimate; nil for factory presets.
    let unboundedDesignRT60Seconds: Double?
    let targetWasClamped: Bool
}

struct RoomComparison: Codable {
    let scenarioID: String
    let designVolumeCubicMeters: Double?
    let validT20Bands: Int
    let meanAbsoluteT20ErrorPercent: Double?
    let legacyMeanAbsoluteT20ErrorPercent: Double?
    let uncalibratedMeanAbsoluteT20ErrorPercent: Double?
    let maximumAbsoluteT20ErrorPercent: Double?
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
    let scenarioSuiteEnabled: Bool
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

struct CalibrationCase {
    let scenarioID: String
    let room: StudioRoomAcousticProfile
    let rawDesignRT60: [Double]?
    let volumeCubicMeters: Double?
}

var cases: [CalibrationCase] = StudioRoomAcousticProfile.starterProfiles.map {
    CalibrationCase(scenarioID: $0.id, room: $0,
                    rawDesignRT60: nil, volumeCubicMeters: nil)
}
cases.append(CalibrationCase(
    scenarioID: arguments.contains("--design-file") ? "supplied-custom" : "default-holdout",
    room: design.makeProfile(), rawDesignRT60: design.predictedRT60,
    volumeCubicMeters: design.volumeCubicMeters
))
let runSuite = arguments.contains("--suite")
if runSuite {
    for scenario in StudioAcousticCalibrationScenario.contrastingRooms {
        cases.append(CalibrationCase(
            scenarioID: scenario.id, room: scenario.design.makeProfile(),
            rawDesignRT60: scenario.design.predictedRT60,
            volumeCubicMeters: scenario.design.volumeCubicMeters
        ))
    }
    // Explicit offline-only experiment. This algorithm substantially
    // worsened the short-room bass response and MUST NOT be used by
    // Studio's saved custom room, stage, or audio engine.
    let shortCase = StudioAcousticCalibrationScenario.contrastingRooms[0]
    var experimental = shortCase.design.makeProfile()
    experimental.shortRoomFeedbackCalibration = true
    cases.append(CalibrationCase(
        scenarioID: "small-treated-experimental-fit",
        room: experimental,
        rawDesignRT60: shortCase.design.predictedRT60,
        volumeCubicMeters: shortCase.design.volumeCubicMeters
    ))
}
let results: [RoomComparison] = cases.map { item in
    let room = item.room
    // Run both analyzers over the EXACT same synthesized impulse. Any
    // difference is measurement-band leakage, not a change in Studio's DSP.
    let (left, right) = NativeRoomImpulseAnalyzer.render(
        room: room, sampleRate: sampleRate, seconds: seconds
    )
    let measured = NativeRoomImpulseAnalyzer.analyze(
        left: left, right: right, sampleRate: sampleRate, roomID: room.id,
        filter: .cascadedButterworth
    )
    let legacy = NativeRoomImpulseAnalyzer.analyze(
        left: left, right: right, sampleRate: sampleRate, roomID: room.id,
        filter: .legacyWideBand
    )
    // If spectral fitting activated, compare against the original playback
    // DSP with the SAME new measurement filter and room geometry. This
    // isolates a genuine sound-engine change from analysis-only differences.
    let uncalibrated: NativeRoomCalibrationResult?
    if room.shortRoomFeedbackCalibration == true {
        var baseline = room
        baseline.shortRoomFeedbackCalibration = false
        uncalibrated = NativeRoomImpulseAnalyzer.measure(
            room: baseline, sampleRate: sampleRate, seconds: seconds,
            filter: .cascadedButterworth
        )
    } else {
        uncalibrated = nil
    }

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

    let bands: [BandComparison] = zip(measured.bands, targets).enumerated().map { index, pair in
        let (measuredBand, target) = pair
        let t20 = measuredBand.t20Seconds
        let legacyT20 = legacy.bands[index].t20Seconds
        let uncalibratedT20 = uncalibrated?.bands[index].t20Seconds
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
            legacyWideBandT20Seconds: legacyT20,
            legacyWideBandT20ErrorPercent: legacyT20.map { 100 * ($0 - target) / target },
            uncalibratedT20Seconds: uncalibratedT20,
            uncalibratedT20ErrorPercent: uncalibratedT20.map {
                100 * ($0 - target) / target
            },
            measuredT30Seconds: measuredBand.t30Seconds,
            t20DifferenceSeconds: t20.map { $0 - target },
            t20ErrorPercent: t20.map { 100 * ($0 - target) / target },
            suggestedInputDecaySeconds: proposed,
            unboundedDesignRT60Seconds: item.rawDesignRT60?[index],
            targetWasClamped: item.rawDesignRT60.map {
                $0[index] < 0.2 || $0[index] > 15
            } ?? false
        )
    }
    let errors = bands.compactMap { $0.t20ErrorPercent.map(abs) }
    let legacyErrors = bands.compactMap { $0.legacyWideBandT20ErrorPercent.map(abs) }
    let uncalibratedErrors = bands.compactMap {
        $0.uncalibratedT20ErrorPercent.map(abs)
    }
    return RoomComparison(
        scenarioID: item.scenarioID,
        designVolumeCubicMeters: item.volumeCubicMeters,
        validT20Bands: errors.count,
        meanAbsoluteT20ErrorPercent: errors.isEmpty ? nil :
            errors.reduce(0, +) / Double(errors.count),
        legacyMeanAbsoluteT20ErrorPercent: legacyErrors.isEmpty ? nil :
            legacyErrors.reduce(0, +) / Double(legacyErrors.count),
        uncalibratedMeanAbsoluteT20ErrorPercent: uncalibratedErrors.isEmpty ? nil :
            uncalibratedErrors.reduce(0, +) / Double(uncalibratedErrors.count),
        maximumAbsoluteT20ErrorPercent: errors.max(),
        roomID: room.id, roomName: room.name,
        sampleRate: sampleRate, impulseLengthSeconds: seconds,
        targetProvenance: provenance,
        method: "Wet-only native ER + 16-line FDN; new cascaded Butterworth octave-edge HP2/LP2 filter versus legacy wide-Q bandpass (same impulse); Schroeder backward energy integration; not an ISO-calibrated measurement",
        wetOnlyC80dB: measured.wetOnlyC80dB,
        bands: bands
    )
}

let report = Report(
    generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
    scenarioSuiteEnabled: runSuite,
    profileCount: results.count,
    note: "Eight production profiles retain original native playback DSP. A ninth explicitly labeled experiment tests a bounded spectral feedback fit that FAILED acoustic validation and is disabled in all production room designs. The two analyzers compare identical renders; only the experimental entry changes DSP, and it includes an untuned audio baseline. No auto-tuning during playback, no external IR, no ISO/IEC conformance claim.",
    rooms: results
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(report)
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data([10]))
