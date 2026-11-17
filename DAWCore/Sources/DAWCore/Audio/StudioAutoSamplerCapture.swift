import Foundation
import AVFoundation
import AudioToolbox

/// Converts locally installed Audio Unit MIDI instruments into independent
/// Studio Sampler packages. The plug-in is instantiated in a PRIVATE offline
/// AVAudioEngine: existing project tracks and the live engine are untouched.
/// Only Music Device Audio Units are supported in this first milestone.
public enum StudioAutoSamplerCapture {
    public struct Source: Identifiable, Hashable, Sendable {
        public let type: UInt32
        public let subtype: UInt32
        public let manufacturer: UInt32
        public let name: String
        public let vendor: String

        public init(type: UInt32, subtype: UInt32, manufacturer: UInt32,
                    name: String, vendor: String) {
            self.type = type
            self.subtype = subtype
            self.manufacturer = manufacturer
            self.name = name
            self.vendor = vendor
        }

        public var id: String { "\(type)-\(subtype)-\(manufacturer)" }

        fileprivate var componentDescription: AudioComponentDescription {
            AudioComponentDescription(componentType: type, componentSubType: subtype,
                                      componentManufacturer: manufacturer,
                                      componentFlags: 0, componentFlagsMask: 0)
        }
    }

    public struct Preset: Identifiable, Equatable, Sendable {
        public let number: Int
        public let name: String
        public var id: Int { number }
    }

    public enum Coverage: String, CaseIterable, Identifiable, Sendable {
        case quick, standard, deep
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .quick: return "Quick"
            case .standard: return "Standard"
            case .deep: return "Deep"
            }
        }

        public var options: StudioSynthSamplerCapture.Options {
            switch self {
            case .quick:
                return .init(rootNotes: [48, 60, 72], velocities: [100])
            case .standard:
                return .init(rootNotes: [36, 48, 60, 72, 84],
                             velocities: [64, 112])
            case .deep:
                return .init(rootNotes: [36, 42, 48, 54, 60, 66, 72, 78, 84, 90, 96],
                             velocities: [32, 64, 96, 120])
            }
        }
    }

    /// One bounded MIDI capture schedule. The UI displays channels 1...16,
    /// while Core Audio uses the corresponding zero-based 0...15 channel.
    /// The sampling endpoints are always included so a composer's requested
    /// upper playable note is represented by a real captured recording.
    public struct SamplingPlan: Sendable, Equatable {
        public var lowestNote: UInt8
        public var highestNote: UInt8
        public var semitoneStep: UInt8
        public var midiChannel: UInt8
        public var limitPlaybackToRange: Bool
        public var velocities: [UInt8]

        public init(coverage: Coverage = .standard,
                    lowestNote: UInt8? = nil, highestNote: UInt8? = nil,
                    semitoneStep: UInt8? = nil, midiChannel: UInt8 = 1,
                    limitPlaybackToRange: Bool = false) {
            let defaults = coverage.options
            self.lowestNote = lowestNote ?? defaults.rootNotes.first ?? 60
            self.highestNote = highestNote ?? defaults.rootNotes.last ?? 60
            self.semitoneStep = semitoneStep ?? UInt8(
                defaults.rootNotes.count > 1
                    ? Int(defaults.rootNotes[1]) - Int(defaults.rootNotes[0]) : 12)
            self.midiChannel = midiChannel
            self.limitPlaybackToRange = limitPlaybackToRange
            self.velocities = defaults.velocities
        }

        public var rootNotes: [UInt8] {
            guard lowestNote <= 127, highestNote <= 127,
                  lowestNote <= highestNote,
                  (1...24).contains(semitoneStep) else { return [] }
            var notes = stride(from: Int(lowestNote), through: Int(highestNote),
                               by: Int(semitoneStep)).map(UInt8.init)
            if notes.last != highestNote { notes.append(highestNote) }
            return notes
        }

        public var sampleCount: Int { rootNotes.count * velocities.count }

        public var isValid: Bool {
            (1...16).contains(midiChannel) &&
            lowestNote <= highestNote && highestNote <= 127 &&
            (1...24).contains(semitoneStep) &&
            !rootNotes.isEmpty && sampleCount <= 128 &&
            !velocities.isEmpty && Set(velocities).count == velocities.count &&
            velocities.allSatisfy { (1...127).contains($0) }
        }

        public func options(sustainSeconds: Double = 1.5,
                            releaseSeconds: Double = 0.65,
                            sampleRate: Double = 44_100)
            -> StudioSynthSamplerCapture.Options {
            .init(rootNotes: rootNotes, velocities: velocities,
                  sustainSeconds: sustainSeconds,
                  releaseSeconds: releaseSeconds, sampleRate: sampleRate)
        }

        /// Existing factory partitions continue to decide which samples own
        /// notes within the selected range. The optional clamp only prevents
        /// notes outside that range from sounding in the exported instrument.
        public func applyingPlaybackRange(to patch: StudioSamplerPatch)
            -> StudioSamplerPatch {
            guard limitPlaybackToRange, isValid else { return patch }
            var result = patch
            for index in result.zones.indices {
                result.zones[index].lowestNote = max(
                    result.zones[index].lowestNote, lowestNote)
                result.zones[index].highestNote = min(
                    result.zones[index].highestNote, highestNote)
            }
            return result
        }
    }

    public struct Result: Sendable {
        public let patch: StudioSamplerPatch
        public let packageURL: URL
        public let takeCount: Int
    }

    public enum CaptureError: Error, LocalizedError {
        case invalidConfiguration
        case unavailableInstrument
        case unsupportedInstrument
        case presetUnavailable
        case missingConfiguredState
        case invalidConfiguredState
        case cannotRenderOffline
        case renderingFailed
        case silentNote(UInt8)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "Choose an Audio Unit instrument, valid notes, and a nonempty instrument name."
            case .unavailableInstrument:
                return "The selected Audio Unit is not installed or could not be loaded."
            case .unsupportedInstrument:
                return "This Audio Unit is not a MIDI instrument. Auto Sampler currently supports Music Device Audio Units."
            case .presetUnavailable:
                return "The selected Audio Unit factory preset is no longer available."
            case .missingConfiguredState:
                return "This Audio Unit did not expose a saved sound state; use an available factory preset instead."
            case .invalidConfiguredState:
                return "The configured Audio Unit sound state was invalid or too large to restore."
            case .cannotRenderOffline:
                return "This Audio Unit cannot render in Studio's offline capture engine. Real-time capture is not yet supported."
            case .renderingFailed:
                return "The Audio Unit failed or returned invalid audio during sampling."
            case .silentNote(let note):
                return "The instrument produced silence at MIDI note \(note). Adjust its patch or note range and try again."
            case .cancelled:
                return "Auto Sampler capture was cancelled."
            }
        }
    }

    /// Installed and registered MIDI instruments, not effects or file-system
    /// guesses. Requery each time so newly installed AUs are recognized.
    public static func availableSources() -> [Source] {
        let match = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                               componentSubType: 0,
                                               componentManufacturer: 0,
                                               componentFlags: 0, componentFlagsMask: 0)
        let results = AVAudioUnitComponentManager.shared().components(matching: match)
        return results.map { component in
            let d = component.audioComponentDescription
            return Source(type: d.componentType, subtype: d.componentSubType,
                          manufacturer: d.componentManufacturer, name: component.name,
                          vendor: component.manufacturerName)
        }.sorted {
            if $0.vendor != $1.vendor { return $0.vendor < $1.vendor }
            return $0.name < $1.name
        }
    }

    /// Presets are read from an isolated instance; selecting one never changes
    /// any loaded plug-in in the current project.
    public static func presets(for source: Source) async throws -> [Preset] {
        let instrument = try await instantiate(source)
        return (instrument.auAudioUnit.factoryPresets ?? []).map {
            Preset(number: $0.number, name: $0.name)
        }
    }

    /// Decode only bounded property-list data, consistent with PluginHost's
    /// savePreset format. The sound data is used only to restore the temporary
    /// capture instance; it is NOT embedded in the resulting instrument.
    public static func validatedConfiguredState(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let state = propertyList as? [String: Any], !state.isEmpty
        else { throw CaptureError.invalidConfiguredState }
        return state
    }

    /// Call from a detached utility task, NOT an audio callback. A new AU
    /// instance is used so existing user presets and tracks stay unchanged.
    /// The resulting package contains audio files, never the source plug-in.
    public static func capture(source: Source, name: String,
                               options: StudioSynthSamplerCapture.Options = .init(),
                               presetNumber: Int? = nil,
                               configuredState: Data? = nil,
                               plan: SamplingPlan? = nil,
                               sampleDirectory: URL? = nil,
                               packageDirectory: URL? = nil) async throws -> Result {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let captureOptions = plan.map {
            $0.options(sustainSeconds: options.sustainSeconds,
                       releaseSeconds: options.releaseSeconds,
                       sampleRate: options.sampleRate)
        } ?? options
        guard source.type == kAudioUnitType_MusicDevice,
              (plan?.isValid ?? true), captureOptions.isValid,
              !trimmed.isEmpty, trimmed.count <= 120,
              !(presetNumber != nil && configuredState != nil)
        else { throw CaptureError.invalidConfiguration }
        let channel: UInt8 = (plan?.midiChannel ?? 1) - 1
        // Decode and validate before instantiating a plugin or touching disk.
        let restoredState = try configuredState.map(validatedConfiguredState)
        guard !Task<Never, Never>.isCancelled else { throw CaptureError.cancelled }

        let instrument = try await instantiate(source)
        if let presetNumber {
            guard let preset = instrument.auAudioUnit.factoryPresets?.first(where: {
                $0.number == presetNumber
            }) else { throw CaptureError.presetUnavailable }
            instrument.auAudioUnit.currentPreset = preset
        } else if let restoredState {
            // PluginHost also sets both state accessors to restore legacy AUs.
            // This affects ONLY the fresh instance created above.
            instrument.auAudioUnit.fullStateForDocument = restoredState
            instrument.auAudioUnit.fullState = restoredState
        }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-au-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let engine = AVAudioEngine()
        engine.attach(instrument)
        engine.connect(instrument, to: engine.mainMixerNode, format: nil)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: captureOptions.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)
        else { throw CaptureError.cannotRenderOffline }

        do {
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: 512)
            try engine.start()
        } catch {
            throw CaptureError.cannotRenderOffline
        }
        defer {
            engine.stop()
            engine.disableManualRenderingMode()
        }

        var takes: [StudioSamplerFactoryTake] = []
        for root in captureOptions.rootNotes.sorted() {
            for velocity in captureOptions.velocities.sorted() {
                guard !Task<Never, Never>.isCancelled else {
                    throw CaptureError.cancelled
                }
                // Flush voices and effect tails between takes without changing
                // the factory preset chosen on this isolated AU instance.
                instrument.stopNote(root, onChannel: channel)
                instrument.sendMIDIEvent(0xB0 | channel, data1: 120, data2: 0)
                instrument.sendMIDIEvent(0xB0 | channel, data1: 123, data2: 0)
                instrument.auAudioUnit.reset()
                engine.reset()

                let output = staging.appendingPathComponent(
                    "midi-\(root)-velocity-\(velocity).wav")
                try renderOne(instrument, engine: engine, buffer: buffer,
                              note: root, velocity: velocity,
                              channel: channel, options: captureOptions,
                              destination: output)
                takes.append(StudioSamplerFactoryTake(
                    source: output, rootNote: root, velocity: velocity))
            }
        }
        // Audio is complete; release the AU engine BEFORE any file copying
        // or hash-heavy packaging to avoid rendering while doing disk work.
        engine.stop()

        var sampler = try StudioSamplerInstrumentFactory.assemble(
            takes, sampleDirectory: sampleDirectory)
        if let plan {
            sampler = plan.applyingPlaybackRange(to: sampler)
        }
        if sampleDirectory != nil {
            for i in sampler.zones.indices { sampler.zones[i].managedFileName = nil }
        }
        let metadata = StudioSamplerInstrumentPackage.Metadata(
            name: trimmed, category: "Auto Sampler",
            tags: ["Audio Unit", "Native Multisample", source.vendor,
                   configuredState == nil ? "Factory Sound" : "Configured Sound"])
        do {
            let package = try StudioSamplerInstrumentPackage.saveToLibrary(
                sampler, metadata: metadata, in: packageDirectory)
            return Result(patch: sampler, packageURL: package, takeCount: takes.count)
        } catch {
            for zone in sampler.zones where zone.managedFileName != nil {
                try? FileManager.default.removeItem(at: zone.sampleURL)
            }
            throw error
        }
    }

    private static func instantiate(_ source: Source) async throws
        -> AVAudioUnitMIDIInstrument {
        guard source.type == kAudioUnitType_MusicDevice else {
            throw CaptureError.unsupportedInstrument
        }
        return try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: source.componentDescription, options: []) {
                unit, error in
                if let instrument = unit as? AVAudioUnitMIDIInstrument {
                    continuation.resume(returning: instrument)
                } else {
                    continuation.resume(throwing:
                        error ?? CaptureError.unavailableInstrument)
                }
            }
        }
    }

    private static func renderOne(_ instrument: AVAudioUnitMIDIInstrument,
                                  engine: AVAudioEngine, buffer: AVAudioPCMBuffer,
                                  note: UInt8, velocity: UInt8,
                                  channel: UInt8,
                                  options: StudioSynthSamplerCapture.Options,
                                  destination: URL) throws {
        let rate = options.sampleRate
        let writer = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let heldFrames = Int(rate * options.sustainSeconds)
        let totalFrames = heldFrames + Int(rate * options.releaseSeconds)
        var position = 0
        var peak: Float = 0
        instrument.startNote(note, withVelocity: velocity, onChannel: channel)
        defer { instrument.stopNote(note, onChannel: channel) }

        while position < totalFrames {
            if Task<Never, Never>.isCancelled { throw CaptureError.cancelled }
            if position == heldFrames { instrument.stopNote(note, onChannel: channel) }
            let edge = position < heldFrames ? heldFrames : totalFrames
            let count = AVAudioFrameCount(min(512, edge - position))
            guard count > 0,
                  try engine.renderOffline(count, to: buffer) == .success,
                  buffer.frameLength == count,
                  let channels = buffer.floatChannelData
            else { throw CaptureError.cannotRenderOffline }
            for channel in 0..<2 {
                for i in 0..<Int(count) {
                    let value = channels[channel][i]
                    guard value.isFinite else { throw CaptureError.renderingFailed }
                    peak = max(peak, abs(value))
                }
            }
            try writer.write(from: buffer)
            position += Int(count)
        }
        guard peak > 0.000001 else { throw CaptureError.silentNote(note) }
    }
}
