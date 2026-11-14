import AVFoundation
import AudioToolbox

/// One original source-to-microphone capture path. Many instances can send
/// into the SAME microphone bus, yielding real synthetic bleed/spill.
/// Instantiated only for an explicit, bounded microphone-audition graph.
/// Per-block work is scalar + fixed-size buffer processing. No dynamic
/// memory allocation, engine manipulation, or actor hops in render.
public final class NativeMicrophoneSpillAudioUnit: AUAudioUnit {
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var processor: NativeMicrophoneSpillProcessor?
    private var signedGainParameter: AUParameter!
    private var delayParameter: AUParameter!
    private var lowPassParameter: AUParameter!

    public static let signedGainAddress: AUParameterAddress = 0
    public static let delayMillisecondsAddress: AUParameterAddress = 1
    public static let lowPassAlphaAddress: AUParameterAddress = 2

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x47534D43, // 'GSMC' Studio mic capture
        componentManufacturer: 0x4752544E, // 'GRTN'
        componentFlags: 0,
        componentFlagsMask: 0
    )
    private static var registered = false

    @MainActor
    public static func registerIfNeeded() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(
            NativeMicrophoneSpillAudioUnit.self,
            as: componentDescription,
            name: "Garritan Studio: Native Virtual Microphone Capture",
            version: 1
        )
        registered = true
    }

    public override var inputBusses: AUAudioUnitBusArray { inputs }
    public override var outputBusses: AUAudioUnitBusArray { outputs }
    public override var canProcessInPlace: Bool { true }

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100,
                                   channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                     busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                      busses: [outputBus])
        signedGainParameter = AUParameterTree.createParameter(
            withIdentifier: "signedGain", name: "Source Polar Gain",
            address: Self.signedGainAddress,
            min: -2, max: 2, unit: .linearGain, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil
        )
        delayParameter = AUParameterTree.createParameter(
            withIdentifier: "delayMilliseconds", name: "Propagation Delay",
            address: Self.delayMillisecondsAddress,
            min: 0, max: NativeMicrophoneSpillProcessor.maximumDelayMilliseconds,
            unit: .milliseconds, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil
        )
        lowPassParameter = AUParameterTree.createParameter(
            withIdentifier: "lowPassAlpha", name: "Air Damping Coefficient",
            address: Self.lowPassAlphaAddress,
            min: 0.00001, max: 1, unit: .generic, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil
        )
        parameterTree = AUParameterTree.createTree(withChildren: [
            signedGainParameter, delayParameter, lowPassParameter
        ])
        signedGainParameter.value = 0
        delayParameter.value = 0
        lowPassParameter.value = 1
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard outputBus.format.channelCount == 2,
              outputBus.format.commonFormat == .pcmFormatFloat32,
              !outputBus.format.isInterleaved,
              inputBus.format.sampleRate == outputBus.format.sampleRate
        else {
            super.deallocateRenderResources()
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FormatNotSupported))
        }
        processor = NativeMicrophoneSpillProcessor(
            sampleRate: outputBus.format.sampleRate
        )
    }

    public override func deallocateRenderResources() {
        processor = nil
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [self] flags, timestamp, frames, _, outputData, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            let status = pull(flags, timestamp, frames, 0, outputData)
            guard status == noErr else { return status }
            guard let processor else { return kAudioUnitErr_Uninitialized }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            processor.setTargets(
                gain: signedGainParameter.value,
                delayMilliseconds: delayParameter.value,
                lowPassAlpha: lowPassParameter.value
            )
            processor.process(left: left, right: right, frameCount: Int(frames))
            return noErr
        }
    }
}
