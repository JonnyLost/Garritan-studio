import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation
import DAWRealtime

// MARK: - Core Audio Backend

/// Professional-grade audio backend using direct Core Audio APIs
/// Provides sample-accurate timing, direct AudioUnit hosting, and offline bounce
public final class CoreAudioBackend: AudioBackend {
    
    // MARK: - Properties
    
    /// Output Audio Unit (hardware interface)
    private var outputUnit: AudioComponentInstance?
    
    /// Render graph for track/plugin management
    private var renderGraph: RenderGraph!
    
    /// MIDI event scheduler
    private var midiScheduler: MIDIScheduler!
    
    /// Audio clip renderer
    private var audioClipRenderer: AudioClipRenderer!
    
    /// Metronome renderer
    private var metronomeRenderer: MetronomeRenderer!
    
    /// Offline bounce engine
    private var offlineBounce: OfflineBounce!
    
    // MARK: - State (Atomic for thread safety)
    
    private var _isRunning: Bool = false
    /// Owned by this backend for its lifetime; callback reads atomically.
    private let transport: OpaquePointer
    private var playbackStartSample: Int64 = 0
    private var _sampleRate: Double = 44100
    private var _bufferSize: UInt32 = 512
    private var _masterVolume: Float = 1.0
    // Render-thread-owned gain; only modified when consuming commands.
    private var renderedMasterVolume: Float = 1.0
    private let graphCommands = StudioGraphParameterMailbox(capacity: 1024)
    /// Control-only; the audio callback must NEVER enter this gate.
    private let controlGate = StudioGraphControlGate()
    private var _tempo: Double = 120.0
    
    // MARK: - AudioBackend Protocol Properties
    
    public var isRunning: Bool { controlGate.perform { _isRunning } }
    public var sampleRate: Double { _sampleRate }
    public var bufferSize: UInt32 { controlGate.perform { _bufferSize } }
    public var currentSamplePosition: Int64 { daw_render_transport_position(transport) }
    public var isPlaying: Bool { daw_render_transport_is_playing(transport) }
    public var masterVolume: Float { controlGate.perform { _masterVolume } }
    
    // MARK: - Initialization
    
    public init() {
        guard let state = daw_render_transport_create() else {
            preconditionFailure("Unable to allocate native render transport")
        }
        transport = state
        print("[CoreAudioBackend] Initializing...")
        
        // Get sample rate from system
        _sampleRate = getSystemSampleRate()
        
        // Initialize components
        midiScheduler = MIDIScheduler(capacity: 32768)
        renderGraph = RenderGraph(sampleRate: _sampleRate, bufferSize: Int(_bufferSize))
        audioClipRenderer = AudioClipRenderer(sampleRate: _sampleRate)
        metronomeRenderer = MetronomeRenderer(sampleRate: _sampleRate)
        offlineBounce = OfflineBounce(renderGraph: renderGraph, midiScheduler: midiScheduler, audioClipRenderer: audioClipRenderer, metronomeRenderer: metronomeRenderer)
        
        // Setup output unit
        setupOutputUnit()
        
        print("[CoreAudioBackend] Initialized with sample rate: \(_sampleRate)")
    }
    
    deinit {
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
        daw_render_transport_destroy(transport)
    }
    
    // MARK: - Output Unit Setup
    
    private func getSystemSampleRate() -> Double {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        
        propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate
        propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
        
        var sampleRate: Double = 44100
        size = UInt32(MemoryLayout<Double>.size)
        
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &sampleRate)
        
        return sampleRate
    }
    
    private func setupOutputUnit() {
        // Find default output component
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        
        guard let component = AudioComponentFindNext(nil, &desc) else {
            fatalError("[CoreAudioBackend] Could not find default output audio unit")
        }
        
        var status = AudioComponentInstanceNew(component, &outputUnit)
        guard status == noErr, let unit = outputUnit else {
            fatalError("[CoreAudioBackend] Could not create output unit: \(status)")
        }
        
        // Set stream format
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: _sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        
        if status != noErr {
            print("[CoreAudioBackend] Warning: Could not set stream format: \(status)")
        }
        
        // Set render callback
        var callbackStruct = AURenderCallbackStruct(
            inputProc: coreAudioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        
        guard status == noErr else {
            fatalError("[CoreAudioBackend] Could not set render callback: \(status)")
        }
        
        // Initialize
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            fatalError("[CoreAudioBackend] Could not initialize output unit: \(status)")
        }
        
        print("[CoreAudioBackend] Output unit configured")
    }
    
    // MARK: - Lifecycle
    
    public func start() throws {
        return try controlGate.perform {
        try controlGate.ensureMutationAvailable()
        guard let unit = outputUnit, !_isRunning else { return }
        
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioBackendError.failedToStart("AudioOutputUnitStart failed: \(status)")
        }
        
        _isRunning = true
        print("[CoreAudioBackend] Started")
    
        }}
    
    public func stop() {
        controlGate.perform {
        guard !controlGate.isBounceActive else { return }
        guard let unit = outputUnit, _isRunning else { return }
        let status = AudioOutputUnitStop(unit)
        guard status == noErr else { return }
        daw_render_transport_set_playing(transport, false)
        drainGraphCommandsWhileQuiescent()
        audioClipRenderer.pauseStreaming()
        _isRunning = false
        
        print("[CoreAudioBackend] Stopped")
    
        }}
    
    /// Stop the hardware output and drain its in-flight callback before a
    /// control operation mutates transport, MIDI or clip-renderer state.
    /// This is intentionally control-thread-only and may block.
    /// Callers must serialize all experimental backend control operations.
    private func withDrainedOutput(_ body: () -> Void) {
        controlGate.perform {
        guard !controlGate.isBounceActive else { return }
        let restart = _isRunning
        if restart, let outputUnit {
            let stopStatus = AudioOutputUnitStop(outputUnit)
            guard stopStatus == noErr else {
                // Never mutate callback-owned objects if output drain fails.
                return
            }
        }
        drainGraphCommandsWhileQuiescent()
        body()
        if restart, let outputUnit {
            let result = AudioOutputUnitStart(outputUnit)
            if result != noErr {
                _isRunning = false
                daw_render_transport_set_playing(transport, false)
            }
        }
    
        }}

    /// Install already prepared graph resources while callbacks are drained.
    /// Unlike the old async helper, this never suspends with output stopped.
    /// The caller must serialize all experimental backend control operations.
    private func withDrainedOutputResult<T>(_ operation: () throws -> T) throws -> T {
        return try controlGate.perform {
        try controlGate.ensureMutationAvailable()
        let restart = _isRunning
        if restart, let outputUnit {
            let status = AudioOutputUnitStop(outputUnit)
            guard status == noErr else {
                throw AudioBackendError.configurationError("Cannot drain Core Audio output: \(status)")
            }
        }
        defer {
            if restart, let outputUnit {
                let status = AudioOutputUnitStart(outputUnit)
                if status != noErr {
                    _isRunning = false
                    daw_render_transport_set_playing(transport, false)
                }
            }
        }
        drainGraphCommandsWhileQuiescent()
        return try operation()
    
        }}

    // MARK: - Render-owned parameter commands

    /// Apply only at callback boundaries, or from a control thread AFTER
    /// hardware callbacks have drained. Does not alter graph topology.
    private func applyPendingGraphCommands(maximum: Int = 128) {
        graphCommands.consume(maximum: maximum) { command in
            switch command {
            case let .trackVolume(id, value):
                renderGraph.setTrackVolume(value, for: id)
            case let .trackPan(id, value):
                renderGraph.setTrackPan(value, for: id)
            case let .trackMute(id, muted):
                renderGraph.setTrackMute(muted, for: id)
            case let .masterVolume(value):
                renderedMasterVolume = value
                renderGraph.setMasterVolume(value)
            }
        }
    }

    /// Called only after the output callback has fully stopped.
    /// Preserve ordering when a topology edit or queue overflow occurs.
    private func drainGraphCommandsWhileQuiescent() {
        while graphCommands.pendingCount > 0 {
            applyPendingGraphCommands()
        }
    }

    /// The producer is the serialized backend control thread.
    /// A full queue uses the existing drained-output path on that thread;
    /// commands are never silently discarded.
    private func submitGraphCommand(_ command: StudioGraphParameterCommand) {
        controlGate.perform {
        guard !controlGate.isBounceActive else { return }
        if !_isRunning {
            drainGraphCommandsWhileQuiescent()
            applyGraphCommandImmediately(command)
            return
        }
        if !graphCommands.submit(command) {
            withDrainedOutput {
                applyGraphCommandImmediately(command)
            }
        }
    
        }}

    /// Only valid when the output callback is stopped.
    private func applyGraphCommandImmediately(_ command: StudioGraphParameterCommand) {
        switch command {
        case let .trackVolume(id, value):
            renderGraph.setTrackVolume(value, for: id)
        case let .trackPan(id, value):
            renderGraph.setTrackPan(value, for: id)
        case let .trackMute(id, muted):
            renderGraph.setTrackMute(muted, for: id)
        case let .masterVolume(value):
            renderedMasterVolume = value
            renderGraph.setMasterVolume(value)
        }
    }

    // MARK: - Track Management
    
    public func createTrack(id: TrackID) throws {
        // Adding an empty route publishes a new immutable membership list.
        // The active render callback still holds its old snapshot until its
        // read epoch ends, so this one topology operation needs no output
        // stop/restart. Removal and AU changes still require hardware drain.
        try controlGate.perform {
            try controlGate.ensureMutationAvailable()
            renderGraph.createTrack(id: id)
        }
    }
    
    public func removeTrack(id: TrackID) {
        withDrainedOutput { renderGraph.removeTrack(id: id) }
    }
    
    public func setTrackVolume(_ volume: Float, for trackID: TrackID) {
        submitGraphCommand(.trackVolume(trackID, volume))
    }
    
    public func setTrackPan(_ pan: Float, for trackID: TrackID) {
        submitGraphCommand(.trackPan(trackID, pan))
    }
    
    public func setTrackMute(_ muted: Bool, for trackID: TrackID) {
        submitGraphCommand(.trackMute(trackID, muted))
    }
    
    // MARK: - Plugin Hosting
    
    public func loadInstrument(
        _ description: AudioComponentDescription,
        for trackID: TrackID
    ) async throws -> AudioUnit {
        // The new AU is isolated from the active graph until preparation ends.
        // The hardware drain now covers only the synchronous owner swap.
        // Capture configuration under the same control gate used by resize.
        // A stale prepared AU is rejected instead of installing with the
        // wrong maximum render slice after a concurrent buffer-size change.
        let preparedFrames = controlGate.perform { _bufferSize }
        let prepared = try await renderGraph.prepareInstrument(
            description, maximumFrames: preparedFrames
        )
        return try withDrainedOutputResult {
            guard _bufferSize == preparedFrames else {
                throw AudioBackendError.configurationError(
                    "Audio buffer size changed during instrument preparation; retry load"
                )
            }
            return try renderGraph.installInstrument(prepared, for: trackID)
        }
    }
    
    public func loadEffect(
        _ description: AudioComponentDescription,
        for trackID: TrackID,
        slot: Int
    ) async throws -> AudioUnit {
        // Initialize the new effect before disturbing hardware playback.
        let prepared = try renderGraph.prepareEffect(description)
        return try withDrainedOutputResult {
            try renderGraph.installEffect(prepared, for: trackID, slot: slot)
        }
    }
    
    public func unloadPlugin(for trackID: TrackID, slot: Int) {
        withDrainedOutput { renderGraph.unloadPlugin(for: trackID, slot: slot) }
    }
    
    public func getInstrumentAudioUnit(for trackID: TrackID) -> AudioUnit? {
        controlGate.perform {
        return renderGraph.getInstrumentUnit(for: trackID)
    
        }}
    
    // MARK: - MIDI
    
    private var scheduledEventCount = 0
    
    public func scheduleMIDIEvent(_ event: ScheduledMIDIEvent) {
        controlGate.perform {
        guard !controlGate.isBounceActive else { return }
        midiScheduler.schedule(event)
        scheduledEventCount += 1
    
        }}
    
    public func sendImmediateMIDI(status: UInt8, data1: UInt8, data2: UInt8, to trackID: TrackID) {
        controlGate.perform {
        guard !controlGate.isBounceActive else { return }
        guard let unit = renderGraph.getInstrumentUnit(for: trackID) else {
            #if DEBUG
            print("[Preview MIDI] CoreAudio routing FAILED: no instrument unit for track=\(trackID.rawValue) status=\(status) pitch=\(data1)")
            #endif
            return
        }
        let result = MusicDeviceMIDIEvent(unit, UInt32(status), UInt32(data1), UInt32(data2), 0)
        #if DEBUG
        if result != noErr {
            print("[Preview MIDI] CoreAudio delivery FAILED: OSStatus=\(result) track=\(trackID.rawValue) status=\(status) pitch=\(data1)")
        }
        #endif
    
        }}
    
    public func clearScheduledMIDIEvents() {
        withDrainedOutput { midiScheduler.clear() }
    }
    
    // MARK: - Audio Clips
    
    public func scheduleAudioClip(
        url: URL,
        trackID: TrackID,
        startSample: Int64,
        offsetSample: Int64,
        endSample: Int64,
        volume: Float
    ) throws {
        try controlGate.perform {
            try controlGate.ensureMutationAvailable()
            guard !isPlaying else {
                throw AudioBackendError.configurationError(
                    "Stop experimental Core Audio playback before editing audio clips"
                )
            }
            try withDrainedOutputResult {
                try audioClipRenderer.scheduleClip(
                    url: url, trackID: trackID, startSample: startSample,
                    offsetSample: offsetSample, endSample: endSample, volume: volume
                )
            }
        }
    }

    public func clearAudioClips() {
        withDrainedOutput {
            daw_render_transport_set_playing(transport, false)
            audioClipRenderer.clearClips()
        }
    }

    // MARK: - Playback Control
    
    
    public func play(from samplePosition: Int64) {
        withDrainedOutput {
            daw_render_transport_set_playing(transport, false)
            audioClipRenderer.preparePlayback(at: samplePosition)
            playbackStartSample = samplePosition
            daw_render_transport_set_position(transport, samplePosition)
            daw_render_transport_set_playing(transport, true)
        }
    }

    public func pause() {
        withDrainedOutput {
            daw_render_transport_set_playing(transport, false)
            audioClipRenderer.pauseStreaming()
        }
    }

    public func stopPlayback() {
        withDrainedOutput {
            daw_render_transport_set_playing(transport, false)
            audioClipRenderer.pauseStreaming()
            renderGraph.allNotesOff()
        }
    }

    public func seek(to samplePosition: Int64) {
        withDrainedOutput {
            let resume = isPlaying
            daw_render_transport_set_playing(transport, false)
            audioClipRenderer.preparePlayback(at: samplePosition)
            playbackStartSample = samplePosition
            daw_render_transport_set_position(transport, samplePosition)
            daw_render_transport_set_playing(transport, resume)
        }
    }

    // MARK: - Metronome
    
    public func setMetronomeEnabled(_ enabled: Bool) {
        controlGate.perform {
        withDrainedOutput { metronomeRenderer.isEnabled = enabled }
    
        }}
    
    public func setMetronomeVolume(_ volume: Float) {
        controlGate.perform {
        withDrainedOutput { metronomeRenderer.volume = volume }
    
        }}
    
    public func scheduleMetronomeClicks(
        from startBeat: Double,
        to endBeat: Double,
        tempo: Double,
        timeSignature: TimeSignature
    ) {
        controlGate.perform {
        withDrainedOutput {
            _tempo = tempo
            metronomeRenderer.scheduleClicks(
                from: startBeat,
                to: endBeat,
                tempo: tempo,
                sampleRate: _sampleRate,
                timeSignature: timeSignature
            )
        }
    
        }}
    
    // MARK: - Offline Bounce
    
    public func bounceOffline(
        from startSample: Int64,
        to endSample: Int64,
        outputURL: URL,
        progress: ((Double) -> Void)?
    ) async throws {
        // Reserve the shared render graph across the entire asynchronous
        // export, not just the first await. Hardware callbacks MUST be
        // completely stopped before the offline renderer owns the AUs.
        let shouldRestartOutput = try controlGate.perform { () throws -> Bool in
            guard !controlGate.isBounceActive else {
                throw StudioGraphLeaseError.alreadyExporting
            }
            guard !isPlaying else {
                throw AudioBackendError.configurationError(
                    "Stop realtime playback before offline bounce"
                )
            }
            guard endSample > startSample, startSample >= 0 else {
                throw AudioBackendError.configurationError(
                    "Offline bounce range must have a positive duration"
                )
            }
            let wasRunning = _isRunning
            if wasRunning, let outputUnit {
                let status = AudioOutputUnitStop(outputUnit)
                guard status == noErr else {
                    throw AudioBackendError.configurationError(
                        "Cannot drain hardware output before bounce: \(status)"
                    )
                }
            }
            // The callback is quiescent. Drain leftover render-owned commands
            // and stop the clip prefetch worker before taking the graph lease.
            drainGraphCommandsWhileQuiescent()
            audioClipRenderer.pauseStreaming()
            guard controlGate.beginBounceLease() else {
                throw StudioGraphLeaseError.alreadyExporting
            }
            return wasRunning
        }

        defer {
            controlGate.perform {
                controlGate.endBounceLease()
                if shouldRestartOutput, let outputUnit {
                    let status = AudioOutputUnitStart(outputUnit)
                    if status != noErr {
                        _isRunning = false
                        daw_render_transport_set_playing(transport, false)
                    }
                }
            }
        }

        try await offlineBounce.bounce(
            from: startSample,
            to: endSample,
            outputURL: outputURL,
            sampleRate: _sampleRate,
            // Clip offline decoding currently uses a 4096-frame scratch page.
            // Never request more than that or the graph's current capacity.
            bufferSize: min(_bufferSize, UInt32(AudioClipRenderer.pageFrames)),
            progress: progress
        )
    }

    // MARK: - Configuration
    
    public func setBufferSize(_ size: UInt32) throws {
        return try controlGate.perform {
        try controlGate.ensureMutationAvailable()
        guard let unit = outputUnit else { return }
        let restart = _isRunning
        if restart {
            let stopped = AudioOutputUnitStop(unit)
            guard stopped == noErr else {
                throw AudioBackendError.configurationError("Cannot drain output for buffer resize: \(stopped)")
            }
        }
        defer {
            if restart {
                let started = AudioOutputUnitStart(unit)
                if started != noErr {
                    _isRunning = false
                    daw_render_transport_set_playing(transport, false)
                }
            }
        }
        
        var bufferFrameSize = size
        let status = AudioUnitSetProperty(
            unit,
            kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global,
            0,
            &bufferFrameSize,
            UInt32(MemoryLayout<UInt32>.size)
        )
        
        if status == noErr {
            _bufferSize = size
            renderGraph.setBufferSize(Int(size))
            print("[CoreAudioBackend] Buffer size set to \(size)")
        } else {
            throw AudioBackendError.configurationError("Could not set buffer size: \(status)")
        }
    
        }}
    
    public func setMasterVolume(_ volume: Float) {
        controlGate.perform {
        guard !controlGate.isBounceActive else { return }
        _masterVolume = volume
        submitGraphCommand(.masterVolume(volume))
    
        }}
    
    // MARK: - Render Callback (Called from Audio Thread)
    
    /// The main render function - called from the audio thread
    /// This is where all sample-accurate processing happens
    func render(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32,
        bufferList: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let bufferList = bufferList else { return noErr }
        
        // Clear output buffer
        clearBuffer(bufferList, frameCount: frameCount)
        
        // Parameter changes remain responsive while transport is stopped.
        applyPendingGraphCommands()

        guard isPlaying else {
            // Output silence when not playing
            return noErr
        }
        
        let startSample = daw_render_transport_position(transport)
        let endSample = StudioMIDIClockMath.bufferEnd(
            startSample: startSample, frameCount: frameCount
        )

        // The Core Audio render callback must never print or allocate
        // diagnostic strings. The MIDI scheduler returns an event count for
        // non-render diagnostics, not console logging on this thread.
        _ = midiScheduler.processEvents(
            startSample: startSample,
            endSample: endSample,
            renderGraph: renderGraph
        )
        
        // 2. Render all tracks through the graph
        renderGraph.render(
            frameCount: frameCount,
            currentSample: startSample,
            outputBuffer: bufferList
        )
        
        // 3. Render audio clips
        audioClipRenderer.render(
            into: bufferList,
            currentSample: startSample,
            frameCount: frameCount
        )
        
        // 4. Render metronome
        metronomeRenderer.render(
            into: bufferList,
            currentSample: startSample,
            frameCount: frameCount
        )
        
        // 5. Apply master volume
        applyMasterVolume(bufferList, volume: renderedMasterVolume, frameCount: frameCount)
        
        // 6. Update position
        daw_render_transport_set_position(transport, endSample)
        
        return noErr
    }
    
    // MARK: - Buffer Helpers
    
    private func clearBuffer(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in ablPointer {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
    
    private func applyMasterVolume(_ bufferList: UnsafeMutablePointer<AudioBufferList>, volume: Float, frameCount: UInt32) {
        guard volume != 1.0 else { return }
        
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in ablPointer {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<Int(frameCount) {
                data[i] *= volume
            }
        }
    }
}

// MARK: - Render Callback (C Function)

/// The C render callback that bridges to Swift
private func coreAudioRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let backend = Unmanaged<CoreAudioBackend>.fromOpaque(inRefCon).takeUnretainedValue()
    return backend.render(
        ioActionFlags: ioActionFlags,
        timeStamp: inTimeStamp,
        busNumber: inBusNumber,
        frameCount: inNumberFrames,
        bufferList: ioData
    )
}
