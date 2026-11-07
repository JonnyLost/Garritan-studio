import AVFoundation
import AudioToolbox

/// In-process Audio Unit wrapper for StereoPositionProcessor.
/// Registered as an in-process effect for AVAudioEngine track insertion.
public final class StereoPositionAudioUnit: AUAudioUnit {
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var positionParameter: AUParameter!
    private var processor = StereoPositionProcessor()

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4753504E, // 'GSPN'
        componentManufacturer: 0x4752544E, // 'GRTN'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var registered = false

    /// Register before creating any AVAudioUnitEffect instances.
    public static func registerIfNeeded() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(
            StereoPositionAudioUnit.self,
            as: componentDescription,
            name: "Garritan Studio: Stereo Position",
            version: UInt32(1)
        )
        registered = true
    }

    public override var inputBusses: AUAudioUnitBusArray { inputs }
    public override var outputBusses: AUAudioUnitBusArray { outputs }
    public override var canProcessInPlace: Bool { true }

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        positionParameter = AUParameterTree.createParameter(
            withIdentifier: "pan", name: "Stereo Position", address: 0,
            min: -1, max: 1, unit: .generic, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil
        )
        parameterTree = AUParameterTree.createTree(withChildren: [positionParameter])
        positionParameter.value = 0

    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [self] actionFlags, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let status = pullInputBlock(actionFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            processor.setPan(positionParameter.value)
            processor.process(left: left, right: right, frameCount: Int(frameCount))
            return noErr
        }
    }
}
