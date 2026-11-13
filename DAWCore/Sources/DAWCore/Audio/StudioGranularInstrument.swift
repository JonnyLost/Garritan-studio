import Foundation
import AVFoundation
import AudioToolbox
import StudioGranularDSP

public enum StudioGranularError: Error, LocalizedError {
    case invalidConfiguration
    case invalidPatch
    case cannotReadSource(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Granular could not initialize its native renderer."
        case .invalidPatch: return "Granular contains an invalid sound parameter."
        case .cannotReadSource(let message): return "Cannot load granular audio: \(message)"
        }
    }
}

private final class StudioGranularRenderState {
    let synth: OpaquePointer
    init(_ synth: OpaquePointer) { self.synth = synth }
    deinit { sgr_destroy(synth) }
}

/// Original native granular synthesizer. The source is prepared before the
/// AVAudioSourceNode is attached: the real-time callback only reads immutable
/// PCM and fixed-size grain/voice arrays. An imported audio file is limited to
/// 524,288 frames, deliberately avoiding disk work on the callback.
public final class StudioGranularInstrument {
    public let audioNode: AVAudioSourceNode
    public let format: AVAudioFormat
    private let state: StudioGranularRenderState
    private let midiProducerLock = NSLock()

    public init(sampleRate: Double, voices: Int32 = 8,
                patch: StudioGranularPatch = StudioGranularPatch()) throws {
        guard patch.validate() else { throw StudioGranularError.invalidPatch }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        ), format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved,
           let synth = sgr_create(sampleRate, voices) else {
            throw StudioGranularError.invalidConfiguration
        }
        let state = StudioGranularRenderState(synth)
        self.state = state
        self.format = format

        if let path = patch.importedAudioPath {
            try Self.loadFileStopped(at: URL(fileURLWithPath: path), into: synth)
        } else {
            guard sgr_select_factory_source_stopped(synth,
                Int32(patch.source.rawValue)) != 0 else {
                throw StudioGranularError.invalidConfiguration
            }
        }
        for parameter in StudioGranularParameter.allCases {
            guard sgr_set_parameter(synth, parameter.rawValue,
                                    patch.value(for: parameter)) != 0 else {
                throw StudioGranularError.invalidPatch
            }
        }
        audioNode = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers=UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == 2,
                  buffers[0].mNumberChannels == 1,
                  buffers[1].mNumberChannels == 1,
                  let left=buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right=buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudio_ParamError }
            sgr_render(state.synth,left,right,Int32(count))
            return noErr
        }
    }

    private static func loadFileStopped(at url: URL,
                                        into synth: OpaquePointer) throws {
        // AVAudioFile handles compressed-file decode and channel conversion.
        // This method executes only during instrument construction.
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw StudioGranularError.cannotReadSource(error.localizedDescription)
        }
        let capacity=Int(min(file.length, Int64(SGR_MAX_SOURCE_FRAMES)))
        guard capacity >= 128,
              let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(capacity))
        else { throw StudioGranularError.cannotReadSource("The file is too short.") }
        do {
            try file.read(into:buffer,frameCount:AVAudioFrameCount(capacity))
        } catch {
            throw StudioGranularError.cannotReadSource(error.localizedDescription)
        }
        let count=Int(buffer.frameLength)
        guard count >= 128, let channels=buffer.floatChannelData else {
            throw StudioGranularError.cannotReadSource("The decoder returned no audio.")
        }
        let channelCount=Int(buffer.format.channelCount)
        guard channelCount >= 1 else {
            throw StudioGranularError.cannotReadSource("No readable channels.")
        }
        var mono=[Float](repeating:0,count:count)
        let scale=Float(1)/Float(channelCount)
        for channel in 0..<channelCount {
            let pointer=channels[channel]
            for frame in 0..<count { mono[frame] += pointer[frame]*scale }
        }
        let accepted=mono.withUnsafeBufferPointer { samples in
            sgr_load_pcm_stopped(synth,samples.baseAddress,
                                 Int32(count),file.processingFormat.sampleRate)
        }
        guard accepted != 0 else {
            throw StudioGranularError.cannotReadSource(
                "The decoded PCM source could not be prepared.")
        }
    }

    public var sourceFrameCount: Int {
        Int(sgr_source_frames(state.synth))
    }

    @discardableResult
    public func midiMessage(status: UInt8,data1: UInt8,data2: UInt8,
                            frameOffset: UInt32 = 0) -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sgr_midi_event(state.synth,status,data1,data2,frameOffset) != 0
    }

    @discardableResult
    public func noteOn(_ pitch: UInt8,velocity: UInt8,
                       channel: UInt8 = 0) -> Bool {
        midiMessage(status:0x90 | (channel & 15),data1:pitch,data2:velocity)
    }
    @discardableResult
    public func noteOff(_ pitch: UInt8,channel: UInt8 = 0) -> Bool {
        midiMessage(status:0x80 | (channel & 15),data1:pitch,data2:0)
    }
    @discardableResult
    public func controller(_ cc: UInt8,value: UInt8,channel: UInt8 = 0) -> Bool {
        midiMessage(status:0xB0 | (channel & 15),data1:cc,data2:value)
    }
    @discardableResult
    public func allNotesOff() -> Bool {
        midiProducerLock.lock()
        defer { midiProducerLock.unlock() }
        return sgr_all_notes_off(state.synth) != 0
    }
    @discardableResult
    public func setParameter(_ parameter:StudioGranularParameter,value:Float) -> Bool {
        parameter.valid(value) &&
            sgr_set_parameter(state.synth,parameter.rawValue,value) != 0
    }
    public func parameter(_ parameter:StudioGranularParameter) -> Float {
        sgr_get_parameter(state.synth,parameter.rawValue)
    }
}
