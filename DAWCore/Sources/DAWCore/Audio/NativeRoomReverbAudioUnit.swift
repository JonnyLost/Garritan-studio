import AVFoundation
import AudioToolbox

/// An in-process, wet-only Audio Unit for Studio's original room DSP.
/// The existing Apple Concert Hall remains the default until explicitly
/// selected by the host. Render allocation occurs outside the audio callback.
public final class NativeRoomReverbAudioUnit: AUAudioUnit {
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var processor: NativeRoomReverbProcessor?
    private var designedProfile = StudioAcousticRoomDesign().makeProfile()
    private var availableProfiles: [StudioRoomAcousticProfile] {
        StudioRoomAcousticProfile.starterProfiles + [designedProfile]
    }
    private var roomParameter: AUParameter!

    /// Numeric room index, only interpreted using the stable starterProfiles order.
    public static let roomParameterAddress: AUParameterAddress = 0

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x47535256, // 'GSRV'
        componentManufacturer: 0x4752544E, // 'GRTN'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private static var registered = false

    /// Call on the main actor, before any AVAudioUnitEffect is instantiated.
    @MainActor
    public static func registerIfNeeded() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(
            NativeRoomReverbAudioUnit.self,
            as: componentDescription,
            name: "Garritan Studio: Native Room Reverb (Prototype)",
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
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        roomParameter = AUParameterTree.createParameter(
            withIdentifier: "room",
            name: "Room Profile",
            address: Self.roomParameterAddress,
            min: 0, max: AUValue(StudioRoomAcousticProfile.playableProfiles.count - 1),
            unit: .indexed, unitName: nil,
            flags: [.flag_IsReadable, .flag_IsWritable],
            valueStrings: StudioRoomAcousticProfile.playableProfiles.map(\.name),
            dependentParameters: nil
        )
        parameterTree = AUParameterTree.createTree(withChildren: [roomParameter])
        roomParameter.value = 0
    }

    /// Apply only while AVAudioEngine is stopped. The 16-line network
    /// rebuilds off the callback with the selected room's six-band damping.
    public func configureDesignedRoom(_ design: StudioAcousticRoomDesign) {
        designedProfile = design.makeProfile()
        if renderResourcesAllocated {
            processor = NativeRoomReverbProcessor(
                sampleRate: outputBus.format.sampleRate,
                profiles: availableProfiles,
                includeEarlyReflections: false
            )
        }
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        guard format.channelCount == 2, format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              inputBus.format.sampleRate == format.sampleRate else {
            super.deallocateRenderResources()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        processor = NativeRoomReverbProcessor(
            sampleRate: format.sampleRate,
            profiles: availableProfiles,
            includeEarlyReflections: false  // Dedicated per-track ER sidechain
        )
    }

    public override func deallocateRenderResources() {
        processor = nil
        super.deallocateRenderResources()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return { [self] actionFlags, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let status = pullInputBlock(actionFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            guard let processor else { return kAudioUnitErr_Uninitialized }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            // AUParameter receives host/UI writes; expensive coefficient calculations
            // and all room taps were prepared in allocateRenderResources().
            let requested = roomParameter.value
            let index = requested.isFinite ? min(
                StudioRoomAcousticProfile.playableProfiles.count - 1,
                max(0, Int(requested.rounded()))
            ) : 0
            processor.selectProfile(at: index)
            processor.process(left: left, right: right, frameCount: Int(frameCount))
            return noErr
        }
    }
}
