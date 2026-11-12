import Foundation
import DAWCore

/// Run on macOS: swift run -c release RoomAcousticCalibration
/// This tool is for development measurements, not an in-app audio processor.
struct BandComparison: Codable {
    let centerHz: Double
    let intendedRT60Seconds: Double
    let measuredEDTSeconds: Double?
    let measuredT20Seconds: Double?
    let measuredT30Seconds: Double?
    let t20DifferenceSeconds: Double?
    let suggestedInputDecaySeconds: Double?
}

struct RoomComparison: Codable {
    let roomID: String
    let roomName: String
    let sampleRate: Double
    let impulseLengthSeconds: Double
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

let results = StudioRoomAcousticProfile.starterProfiles.map { room -> RoomComparison in
    let measured = NativeRoomImpulseAnalyzer.measure(
        room: room, sampleRate: sampleRate, seconds: seconds
    )
    let targets = [Double(room.bassRT60), Double(room.midRT60),
                   Double(room.trebleRT60)]
    let bands = zip(measured.bands, targets).map { pair -> BandComparison in
        let (band, intended) = pair
        let t20 = band.t20Seconds
        let proposed: Double?
        if let t20, t20 > 0.1 {
            // Only a first-order offline tuning suggestion. Frequency bands
            // interact within the FDN; never persist it automatically.
            proposed = min(15, max(0.2, intended * intended / t20))
        } else {
            proposed = nil
        }
        return BandComparison(
            centerHz: band.bandCenterHz,
            intendedRT60Seconds: intended,
            measuredEDTSeconds: band.edtSeconds,
            measuredT20Seconds: t20,
            measuredT30Seconds: band.t30Seconds,
            t20DifferenceSeconds: t20.map { $0 - intended },
            suggestedInputDecaySeconds: proposed
        )
    }
    return RoomComparison(
        roomID: room.id, roomName: room.name, sampleRate: sampleRate,
        impulseLengthSeconds: seconds,
        method: "Offline wet-only 16-line FDN, approximate 2nd-order octave bandpass, Schroeder backward integration; NO real-room impulse reference",
        wetOnlyC80dB: measured.wetOnlyC80dB,
        bands: bands
    )
}

let report = Report(
    generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
    profileCount: results.count,
    note: "Development measurements of synthesized wet-only impulses. Not calibrated venue acoustics or ISO 3382-compliant room measurements. Compare against published targets only when conditions/frequencies are equivalent.",
    rooms: results
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(report)
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data([10]))
