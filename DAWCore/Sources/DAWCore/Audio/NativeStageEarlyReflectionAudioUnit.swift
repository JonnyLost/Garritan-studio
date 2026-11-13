import AVFoundation
import AudioToolbox

/// Wet-only early reflection Audio Unit. One instance per instrument *only when
/// native room acoustics are enabled*. Controls are polled on the render thread
/// and never trigger storage allocation.
public final class NativeStageEarlyReflectionAudioUnit: AUAudioUnit {
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var processor: NativeStageEarlyReflectionProcessor?
    private var designedProfile = StudioAcousticRoomDesign().makeProfile()
    private var availableProfiles: [StudioRoomAcousticProfile] {
        StudioRoomAcousticProfile.starterProfiles + [designedProfile]
    }

    private var roomParameter: AUParameter!
    private var panParameter: AUParameter!
    private var zoneParameter: AUParameter!

    public static let roomAddress: AUParameterAddress = 0
    public static let panAddress: AUParameterAddress = 1
    public static let zoneAddress: AUParameterAddress = 2

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x47534552, // 'GSER'
        componentManufacturer: 0x4752544E, // 'GRTN'
        componentFlags: 0,
        componentFlagsMask: 0
    )
    private static var registered = false

    @MainActor
    public static func registerIfNeeded() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(
            NativeStageEarlyReflectionAudioUnit.self,
            as: componentDescription,
            name: "Garritan Studio: Stage Early Reflections",
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
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        roomParameter = AUParameterTree.createParameter(
            withIdentifier: "room", name: "Room Profile", address: Self.roomAddress,
            min: 0, max: AUValue(StudioRoomAcousticProfile.playableProfileCount - 1),
            unit: .indexed, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: StudioRoomAcousticProfile.playableProfiles.map(\.name),
            dependentParameters: nil
        )
        panParameter = AUParameterTree.createParameter(
            withIdentifier: "pan", name: "Stage Pan", address: Self.panAddress,
            min: -1, max: 1, unit: .generic, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: nil, dependentParameters: nil
        )
        zoneParameter = AUParameterTree.createParameter(
            withIdentifier: "zone", name: "Stage Depth", address: Self.zoneAddress,
            min: 0, max: 5, unit: .indexed, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: ["Dry", "L1", "L2", "L3", "L4", "L5"],
            dependentParameters: nil
        )
        parameterTree = AUParameterTree.createTree(withChildren: [
            roomParameter, panParameter, zoneParameter
        ])
        roomParameter.value = 0
        panParameter.value = 0
        zoneParameter.value = 2
    }

    /// Apply only with engine stopped; render thread never resizes taps.
    public func configureDesignedRoom(_ design: StudioAcousticRoomDesign) {
        designedProfile = design.makeProfile()
        if renderResourcesAllocated {
            processor = NativeStageEarlyReflectionProcessor(
                sampleRate: outputBus.format.sampleRate,
                profiles: availableProfiles
            )
        }
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        guard format.channelCount == 2, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved, inputBus.format.sampleRate == format.sampleRate
        else {
            super.deallocateRenderResources()
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FormatNotSupported))
        }
        processor = NativeStageEarlyReflectionProcessor(
            sampleRate: format.sampleRate, profiles: availableProfiles
        )
    }

    public override func deallocateRenderResources() {
        processor = nil
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [self] flags, time, frames, _, outputData, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            let status = pull(flags, time, frames, 0, outputData)
            guard status == noErr else { return status }
            guard let processor else { return kAudioUnitErr_Uninitialized }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }

            let requested = roomParameter.value
            let selected = requested.isFinite ?
                min(StudioRoomAcousticProfile.playableProfileCount - 1,
                    max(0, Int(requested.rounded()))) : 0
            let requestedZone = zoneParameter.value
            let depth = requestedZone.isFinite ?
                min(5, max(0, Int(requestedZone.rounded()))) : 0
            processor.update(roomIndex: selected, pan: panParameter.value, zone: depth)
            processor.process(left: left, right: right, frameCount: Int(frames))
            return noErr
        }
    }
}
