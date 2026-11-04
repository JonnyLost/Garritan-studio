import Foundation
import AVFoundation
import AudioToolbox

/// A minimal, standalone Audio Unit hosting experiment for installed ARIA Player.
/// This does not replace the DAW's existing audio graph or modify Garritan content.
/// Run it on the user's Mac before integrating with track routing and project state.
@MainActor
public final class ARIAAudioUnitPrototype {
    public enum HostError: Error, LocalizedError {
        case notFound
        case notMIDIInstrument
        case notLoaded

        public var errorDescription: String? {
            switch self {
            case .notFound: return "No ARIA Audio Unit instrument was found. Check the AU installation."
            case .notMIDIInstrument: return "ARIA loaded but is not exposed as a MIDI instrument."
            case .notLoaded: return "Load the ARIA instrument before sending MIDI."
            }
        }
    }

    public let engine = AVAudioEngine()
    public private(set) var instrument: AVAudioUnitMIDIInstrument?

    /// Search the system's registered AU music devices. A match is only a
    /// candidate; the host still has to instantiate it successfully.
    public static func availableComponents() -> [AVAudioUnitComponent] {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitComponentManager.shared()
            .components(matching: description)
            .filter { component in
                let searchable = (component.name + " " + component.manufacturerName).lowercased()
                return searchable.contains("aria") || searchable.contains("garritan")
            }
    }

    /// Instantiate an installed ARIA AU and connect stereo output to the Mac.
    /// The original ARIA UI is responsible for selecting the licensed patch.
    public func load() async throws {
        guard let component = Self.availableComponents().first else {
            throw HostError.notFound
        }
        let unit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAudioUnit, Error>) in
            AVAudioUnit.instantiate(with: component.audioComponentDescription, options: []) { unit, error in
                if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(throwing: error ?? HostError.notLoaded)
                }
            }
        }
        guard let midiInstrument = unit as? AVAudioUnitMIDIInstrument else {
            throw HostError.notMIDIInstrument
        }

        engine.attach(midiInstrument)
        engine.connect(midiInstrument, to: engine.mainMixerNode, format: nil)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.disconnectNodeOutput(midiInstrument)
            engine.detach(midiInstrument)
            throw error
        }
        instrument = midiInstrument
    }

    /// Send one note-on; the caller must send note-off after its desired duration.
    public func noteOn(_ note: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) throws {
        guard let instrument else { throw HostError.notLoaded }
        instrument.startNote(note, withVelocity: velocity, onChannel: channel)
    }

    public func noteOff(_ note: UInt8, channel: UInt8 = 0) throws {
        guard let instrument else { throw HostError.notLoaded }
        instrument.stopNote(note, onChannel: channel)
    }

    public func stop() {
        engine.stop()
        if let instrument {
            engine.disconnectNodeOutput(instrument)
            engine.detach(instrument)
        }
        instrument = nil
    }
}
