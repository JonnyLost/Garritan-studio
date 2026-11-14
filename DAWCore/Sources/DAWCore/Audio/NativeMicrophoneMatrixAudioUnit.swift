import AVFoundation
import AudioToolbox

/// Experimental one-source / four-capsule Audio Unit. It uses the shared-
/// history matrix DSP: the source is pulled exactly once for a render quantum,
/// then four independent capsule results are cached for the output busses.
///
/// A full orchestra still uses one instance per source. This avoids the
/// original one-AU-per-(source,microphone) topology, but is NOT a single
/// 64-input Audio Unit. The tested legacy backend remains the default.
public final class NativeMicrophoneMatrixAudioUnit: AUAudioUnit {
    private var inputBus: AUAudioUnitBus!
    private var inputArray: AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!
    private var matrix: NativeMicrophoneCaptureMatrix?
    private var cachedOutputs: [UnsafeMutablePointer<Float>] = []
    private var cachedFrameCapacity = 0
    private var cachedSampleTime: Float64 = .nan
    private var cachedFrameCount: AUAudioFrameCount = 0
    private var gains: [AUParameter] = []
    private var delays: [AUParameter] = []
    private var filters: [AUParameter] = []

    public static let microphoneCount = 4
    public static func gainAddress(_ bus: Int) -> AUParameterAddress {
        AUParameterAddress(bus)
    }
    public static func delayAddress(_ bus: Int) -> AUParameterAddress {
        AUParameterAddress(microphoneCount + bus)
    }
    public static func filterAddress(_ bus: Int) -> AUParameterAddress {
        AUParameterAddress(microphoneCount * 2 + bus)
    }

    public static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x47534D58, // GSMX - Studio mic matrix
        componentManufacturer: 0x4752544E,
        componentFlags: 0,
        componentFlagsMask: 0
    )
    @MainActor private static var registered = false

    @MainActor
    public static func registerIfNeeded() {
        guard !registered else { return }
        AUAudioUnit.registerSubclass(
            NativeMicrophoneMatrixAudioUnit.self,
            as: componentDescription,
            name: "Garritan Studio: Experimental Shared Microphone Matrix",
            version: 1
        )
        registered = true
    }

    public override var inputBusses: AUAudioUnitBusArray { inputArray }
    public override var outputBusses: AUAudioUnitBusArray { outputArray }
    public override var canProcessInPlace: Bool { false }

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100, channels: 2
        )!
        inputBus = try AUAudioUnitBus(format: format)
        inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input,
                                        busses: [inputBus])
        var outputBuses: [AUAudioUnitBus] = []
        for _ in 0..<Self.microphoneCount {
            outputBuses.append(try AUAudioUnitBus(format: format))
        }
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output,
                                         busses: outputBuses)
        var parameters: [AUParameter] = []
        for index in 0..<Self.microphoneCount {
            let gain = AUParameterTree.createParameter(
                withIdentifier: "mic\(index)Gain", name: "Capsule \(index + 1) Gain",
                address: Self.gainAddress(index), min: -2, max: 2,
                unit: .linearGain, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil, dependentParameters: nil
            )
            let delay = AUParameterTree.createParameter(
                withIdentifier: "mic\(index)Delay", name: "Capsule \(index + 1) Delay",
                address: Self.delayAddress(index), min: 0,
                max: NativeMicrophoneCaptureMatrix.maximumDelayMilliseconds,
                unit: .milliseconds, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil, dependentParameters: nil
            )
            let filter = AUParameterTree.createParameter(
                withIdentifier: "mic\(index)Air", name: "Capsule \(index + 1) Air Loss",
                address: Self.filterAddress(index), min: 0.00001, max: 1,
                unit: .generic, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: nil, dependentParameters: nil
            )
            gains.append(gain)
            delays.append(delay)
            filters.append(filter)
            parameters.append(contentsOf: [gain, delay, filter])
        }
        parameterTree = AUParameterTree.createTree(withChildren: parameters)
        for index in 0..<Self.microphoneCount {
            gains[index].value = 0
            delays[index].value = 0
            filters[index].value = 1
        }
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let inputFormat = inputBus.format
        let inputValid = inputFormat.commonFormat == .pcmFormatFloat32 &&
            !inputFormat.isInterleaved && inputFormat.channelCount == 2
        var outputsValid = outputArray.count == Self.microphoneCount
        if outputsValid {
            for index in 0..<Self.microphoneCount {
                let format = outputArray[index].format
                let valid = format.commonFormat == .pcmFormatFloat32 &&
                    !format.isInterleaved && format.channelCount == 2 &&
                    format.sampleRate == inputFormat.sampleRate
                if !valid {
                    outputsValid = false
                    break
                }
            }
        }
        guard inputValid, outputsValid,
              let processor = NativeMicrophoneCaptureMatrix(
                  sampleRate: inputFormat.sampleRate, sources: 1,
                  microphones: Self.microphoneCount
              ) else {
            super.deallocateRenderResources()
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let capacity = Int(maximumFramesToRender)
        guard capacity > 0 else {
            super.deallocateRenderResources()
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_TooManyFramesToProcess))
        }
        cachedOutputs = (0..<Self.microphoneCount).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            return pointer
        }
        cachedFrameCapacity = capacity
        cachedSampleTime = .nan
        cachedFrameCount = 0
        matrix = processor
    }

    public override func deallocateRenderResources() {
        matrix = nil
        for pointer in cachedOutputs {
            pointer.deinitialize(count: cachedFrameCapacity)
            pointer.deallocate()
        }
        cachedOutputs.removeAll()
        cachedFrameCapacity = 0
        cachedSampleTime = .nan
        cachedFrameCount = 0
        super.deallocateRenderResources()
    }

    public override func reset() {
        cachedSampleTime = .nan
        cachedFrameCount = 0
        matrix?.reset()
        super.reset()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        { [self] flags, timestamp, frames, bus, outputData, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            guard let matrix, bus >= 0, bus < Self.microphoneCount,
                  Int(frames) <= cachedFrameCapacity else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
            guard UnsafeMutableAudioBufferListPointer(outputData).count == 2 else {
                return kAudioUnitErr_FormatNotSupported
            }
            let time = timestamp.pointee.mSampleTime
            if time != cachedSampleTime || frames != cachedFrameCount {
                // The first requested output bus carries the upstream input.
                // All capsule outputs are evaluated from that input before
                // overwriting it. Remaining bus pulls at this timestamp reuse
                // the same results and cannot advance the delay line twice.
                let status = pull(flags, timestamp, frames, 0, outputData)
                guard status == noErr else { return status }
                let input = UnsafeMutableAudioBufferListPointer(outputData)
                guard input.count == 2,
                      let inputLeft = input[0].mData?.assumingMemoryBound(to: Float.self),
                      let inputRight = input[1].mData?.assumingMemoryBound(to: Float.self)
                else { return kAudioUnitErr_FormatNotSupported }
                for index in 0..<Self.microphoneCount {
                    _ = matrix.setPath(
                        source: 0, microphone: index,
                        gain: gains[index].value,
                        delayMilliseconds: delays[index].value,
                        lowPassAlpha: filters[index].value
                    )
                }
                var source = NativeMicrophoneCaptureMatrix.Source(
                    left: UnsafePointer(inputLeft), right: UnsafePointer(inputRight)
                )
                let didRender = withUnsafePointer(to: &source) { pointer in
                    let inputs = UnsafeBufferPointer(start: pointer, count: 1)
                    return cachedOutputs.withUnsafeBufferPointer { outputs in
                        matrix.render(sources: inputs, outputs: outputs,
                                      frameCount: Int(frames))
                    }
                }
                guard didRender else { return kAudioUnitErr_FormatNotSupported }
                cachedSampleTime = time
                cachedFrameCount = frames
            }
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard output.count == 2,
                  let left = output[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = output[1].mData?.assumingMemoryBound(to: Float.self)
            else { return kAudioUnitErr_FormatNotSupported }
            let mono = cachedOutputs[bus]
            for index in 0..<Int(frames) {
                let value = mono[index]
                left[index] = value
                right[index] = value
            }
            return noErr
        }
    }
}
