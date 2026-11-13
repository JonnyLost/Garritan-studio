import Foundation
import AVFoundation
import Combine

// MARK: - Audio Engine Errors

public enum AudioEngineError: Error, LocalizedError {
    case engineNotRunning
    case failedToStart(underlying: Error)
    case failedToConnect(from: String, to: String)
    case invalidFormat
    case bufferAllocationFailed
    case nodeNotFound(TrackID)
    case invalidPluginSlot(Int)
    case fileLoadFailed(URL, Error)
    
    public var errorDescription: String? {
        switch self {
        case .engineNotRunning:
            return "Audio engine is not running"
        case .failedToStart(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .failedToConnect(let from, let to):
            return "Failed to connect \(from) to \(to)"
        case .invalidFormat:
            return "Invalid audio format"
        case .bufferAllocationFailed:
            return "Failed to allocate audio buffer"
        case .nodeNotFound(let id):
            return "Audio node not found for track: \(id.rawValue)"
        case .invalidPluginSlot(let index):
            return "Invalid insert effect slot: \(index)"
        case .fileLoadFailed(let url, let error):
            return "Failed to load audio file at \(url): \(error.localizedDescription)"
        }
    }
}

// MARK: - Audio Engine

/// Main audio engine wrapping AVAudioEngine with track management
@MainActor
public final class AudioEngine: ObservableObject {
    // Shared Concert Hall send curve, indexed by persisted stage zone (0...5).
    // Keeping one curve avoids discrepancies between live movement and project loading.
    private static let concertHallSendLevels: [Float] = [0.0, 0.12, 0.20, 0.30, 0.43, 0.58]
    // Gentle direct-sound falloff across the five seating rows. Conductor
    // remains at unity and dry. Reverb remains independently controllable.
    private static let stageDirectLevels: [Float] = [1.0, 1.0, 0.94, 0.88, 0.82, 0.76]

    // MARK: - Properties
    
    /// The underlying AVAudioEngine - exposed for advanced node attachment
    public let engine: AVAudioEngine
    private var trackNodes: [TrackID: TrackAudioNode] = [:]
    private var masterMixer: AVAudioMixerNode
    
    // Stage reverb experiment, step 1: create and attach the processor only.
    // No input/output connections or track sends are installed yet.
    // Keeping the established dry signal path untouched makes startup
    // behavior independently testable before introducing audio routing.
    private let concertHallReverb = AVAudioUnitReverb()
    /// Created only when explicitly enabled; the tested Apple path stays default.
    private var nativeConcertHallReverb: AVAudioUnitEffect?
    private var designedRoom = StudioAcousticRoomDesign()
    @Published public private(set) var virtualMicrophoneSettings = StudioVirtualMicrophoneSettings()
    @Published public private(set) var usesNativeConcertHallReverb = false
    @Published public private(set) var selectedNativeRoomProfileID =
        StudioRoomAcousticProfile.abbeyRoadStudioOne.id
    private let concertHallSendMixer = AVAudioMixerNode()
    private let concertHallReturnMixer = AVAudioMixerNode()
    private let nativeEarlyReflectionMixer = AVAudioMixerNode()
    private var nativeEarlyReflectionMixerConnected = false
    /// Shared hall return level, independent of individual instrument sends.
    @Published public private(set) var concertHallOverallReverb: Float = 1.0

    /// Post-fader stereo peak levels (linear 0...1), refreshed approximately 20 times/sec.
    @Published public private(set) var trackPeakLevels: [TrackID: [Float]] = [:]
    private var trackMeterStates: [TrackID: RealtimeStereoPeakMeter] = [:]
    private var trackMeterTimer: Timer?
    
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var sampleRate: Double = 44100
    @Published public private(set) var bufferSize: AVAudioFrameCount = 512
    
    // Available options for UI
    public static let availableBufferSizes: [AVAudioFrameCount] = [64, 128, 256, 512, 1024, 2048]
    public static let availableSampleRates: [Double] = [44100, 48000, 88200, 96000]
    
    // Current playback position in samples - THIS IS THE MASTER CLOCK
    @Published public private(set) var currentSamplePosition: Int64 = 0
    private var playbackStartSamplePosition: Int64 = 0
    private var playbackStartHostTime: UInt64 = 0
    public private(set) var isPlaying: Bool = false
    
    // Combine publishers for sample-accurate timing
    public let samplePositionSubject = PassthroughSubject<Int64, Never>()
    
    // MIDI event callback - called from audio thread with sample-accurate timing
    // Parameters: (bufferStartSample, bufferFrameCount, tempo)
    public var midiEventCallback: ((Int64, AVAudioFrameCount, Double) -> Void)?
    
    // Current tempo for timing calculations (set by transport)
    public var currentTempo: Double = 120.0
    
    // Timing tap installed flag
    private var timingTapInstalled = false
    private let realtimeSamplePosition = RealtimeSamplePosition()
    private var timingPositionUITimer: Timer?
    
    // Metronome
    private var metronomeNode: MetronomeNode?
    
    // MARK: - Initialization
    
    public init() {
        self.engine = AVAudioEngine()
        self.masterMixer = engine.mainMixerNode
        
        concertHallReverb.loadFactoryPreset(.mediumHall)
        concertHallReverb.wetDryMix = 100
        engine.attach(concertHallReverb)
        engine.attach(concertHallSendMixer)

        // Dedicated Concert Hall return; existing dry routes stay untouched.
        engine.attach(concertHallReturnMixer)

        let hallFormat = AVAudioFormat(
            standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
            channels: 2
        )!

        engine.connect(concertHallSendMixer, to: concertHallReverb, format: hallFormat)
        engine.connect(concertHallReverb, to: concertHallReturnMixer, format: hallFormat)
        engine.connect(concertHallReturnMixer, to: masterMixer, format: hallFormat)

        print("[ConcertHall] Dedicated reverb return connected")
        
        // Get sample rate from output
        sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        
        setupNotifications()
        
        // Prepare the engine for input/output
        prepareEngine()
    }
    
    private func prepareEngine() {
        // Access input node to ensure it's initialized
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("Audio Engine: Input format = \(inputFormat)")
        
        // Access output node
        let outputNode = engine.outputNode
        let outputFormat = outputNode.outputFormat(forBus: 0)
        print("Audio Engine: Output format = \(outputFormat)")
        
        // Make sure input is connected to output (for monitoring capability)
        // Note: We don't actually connect them directly to avoid feedback,
        // but accessing them prepares the hardware
        
        // Prepare the engine
        engine.prepare()
        print("Audio Engine: Prepared")
    }
    
    /// Ensure the engine is running (call this before any audio operations)
    public func ensureRunning() throws {
        if !engine.isRunning {
            try start()
        }
    }
    
    deinit {
        engine.stop()
    }
    
    // MARK: - Engine Control
    
    public func start() throws {
        guard !engine.isRunning else { return }
        
        do {
            try engine.start()
            isRunning = true
        } catch {
            throw AudioEngineError.failedToStart(underlying: error)
        }
    }
    
    public func stop() {
        engine.stop()
        isRunning = false
        isPlaying = false
    }
    
    public func pause() {
        engine.pause()
        isPlaying = false
    }
    
    // MARK: - Track Management

    /// Mixer graphs currently attached to AVAudioEngine. Used to reconcile
    /// track add/delete operations performed through undo and redo.
    public var activeTrackIDs: Set<TrackID> {
        Set(trackNodes.keys)
    }

    /// Create audio nodes for a track
    public func createTrackNode(for track: Track) throws {
        guard trackNodes[track.id] == nil else { return }
        // AVAudioEngine can stall when a new track is connected to a live
        // master mixer. Reconfigure the graph while stopped, then resume.
        let wasRunning = engine.isRunning
        if wasRunning {
            print("[Track Audio] Pausing engine for track graph reconfiguration")
            engine.stop()
        }
        defer {
            if wasRunning {
                do {
                    try engine.start()
                    print("[Track Audio] Engine restarted after track creation")
                } catch {
                    print("[Track Audio] ERROR restarting engine after track creation: \(error)")
                    isRunning = false
                }
            }
        }
        
        print("[Track Audio] Constructing track node")
        let trackNode = TrackAudioNode(
            trackID: track.id,
            channelCount: 2,
            sampleRate: sampleRate
        )
        
        // Instantiate the in-process stereo positioning effect. If unavailable,
        // preserve the original mixer pan path instead of losing audio.
        print("[Track Audio] Registering stereo effect")
        StereoPositionAudioUnit.registerIfNeeded()
        let stereoEffect = AVAudioUnitEffect(audioComponentDescription: StereoPositionAudioUnit.componentDescription)
        trackNode.stereoPositionNode = stereoEffect

        print("[Track Audio] Stereo effect instantiated; attaching nodes")
        // Attach nodes to engine
        engine.attach(trackNode.inputMixer)
        engine.attach(trackNode.gainNode)
        engine.attach(stereoEffect)
        engine.attach(trackNode.pannerNode)
        engine.attach(trackNode.outputMixer)
        engine.attach(trackNode.concertHallSend)
        print("[Track Audio] Nodes attached; connecting hall send")
        engine.connect(
            trackNode.concertHallSend,
            to: concertHallSendMixer,
            format: AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 2
            )!
        )
        
        // Connect: input -> plugins -> gain -> panner -> output
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!
        
        print("[Track Audio] Hall send connected; connecting signal chain")
        engine.connect(trackNode.inputMixer, to: trackNode.gainNode, format: format)
        engine.connect(trackNode.gainNode, to: stereoEffect, format: format)
        engine.connect(stereoEffect, to: trackNode.pannerNode, format: format)
        // Split the post-panner signal into dry and Concert Hall send paths.
        // Both destinations receive the same audio; the send mixer
        // controls how much reaches the shared reverb.
        print("[Track Audio] Connecting split panner output")
        engine.connect(
            trackNode.pannerNode,
            to: [
                AVAudioConnectionPoint(node: trackNode.outputMixer, bus: 0),
                AVAudioConnectionPoint(node: trackNode.concertHallSend, bus: 0)
            ],
            fromBus: 0,
            format: format
        )
        print("[Track Audio] Split connected; connecting master output")
        engine.connect(trackNode.outputMixer, to: masterMixer, format: format)
        if usesNativeConcertHallReverb {
            installStageEarlyReflections(for: trackNode, format: format)
        }
        let dryEdges = engine.outputConnectionPoints(for: trackNode.outputMixer, outputBus: 0)
        print("[ConcertHall] Dry track \(track.id.rawValue) -> master: \(dryEdges.contains { $0.node === masterMixer })")
        print("[ConcertHall] Track output format: \(trackNode.outputMixer.outputFormat(forBus: 0))")
        print("[ConcertHall] Master input format: \(masterMixer.inputFormat(forBus: 0))")
        
        print("[Track Audio] Master output connected; applying parameters")
        // Set initial values
        trackNode.setVolume(track.volume)
        trackNode.setPan(track.pan)
        trackNode.setMuted(track.isMuted)
        
        // Restore saved orchestral stage depth.
        let depth = max(0, min(5, track.stageReverbZone ?? 2))
        trackNode.setStageAcoustics(
            directLevel: Self.stageDirectLevels[depth],
            hallSendLevel: Self.concertHallSendLevels[depth] * max(0, track.stageWetTrim ?? 1),
            zone: depth
        )
        trackNode.setVirtualMicrophone(virtualMicrophoneSettings,
                                       nativeEnabled: usesNativeConcertHallReverb)

        trackNodes[track.id] = trackNode
        print("[Track Audio] Installing meter")
        installTrackMeter(for: trackNode)
        print("[Track Audio] Track node ready")
    }

    /// Meter after volume, mute and stereo positioning, without modifying audio.
    private func installTrackMeter(for trackNode: TrackAudioNode) {
        let id = trackNode.trackID
        let format = trackNode.outputMixer.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.commonFormat == .pcmFormatFloat32,
              let meter = RealtimeStereoPeakMeter() else { return }
        trackMeterStates[id] = meter
        trackNode.outputMixer.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            meter.measure(buffer)
        }

        // Poll all track meters on the UI run loop. This eliminates per-buffer
        // heap allocations and main-queue dispatch from each track's tap.
        if trackMeterTimer == nil {
            trackMeterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for (trackID, meter) in self.trackMeterStates {
                        let peak = meter.takePeaks()
                        self.trackPeakLevels[trackID] = [
                            min(1, peak.left), min(1, peak.right)
                        ]
                    }
                }
            }
        }
    }
    
    /// Remove audio nodes for a track
    public func removeTrackNode(for trackID: TrackID) {
        guard let trackNode = trackNodes[trackID] else { return }

        // Match createTrackNode: graph changes are made while the engine is
        // stopped to avoid stalls when disconnecting a live master mixer.
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        defer {
            if wasRunning {
                do {
                    try engine.start()
                } catch {
                    print("[Track Audio] ERROR restarting engine after track removal: \(error)")
                    isRunning = false
                }
            }
        }

        // Remove metering tap before detaching the output node.
        trackNode.outputMixer.removeTap(onBus: 0)
        trackMeterStates.removeValue(forKey: trackID)
        trackPeakLevels.removeValue(forKey: trackID)
        if trackMeterStates.isEmpty {
            trackMeterTimer?.invalidate()
            trackMeterTimer = nil
        }
        // Disconnect and detach all nodes
        engine.disconnectNodeOutput(trackNode.inputMixer)
        engine.disconnectNodeOutput(trackNode.gainNode)
        if let effect = trackNode.stereoPositionNode { engine.disconnectNodeOutput(effect) }
        engine.disconnectNodeOutput(trackNode.pannerNode)
        engine.disconnectNodeOutput(trackNode.outputMixer)
        engine.disconnectNodeOutput(trackNode.concertHallSend)
        if let send = trackNode.earlyReflectionSend { engine.disconnectNodeOutput(send) }
        if let effect = trackNode.earlyReflectionNode { engine.disconnectNodeOutput(effect) }
        
        engine.detach(trackNode.inputMixer)
        engine.detach(trackNode.gainNode)
        if let effect = trackNode.stereoPositionNode { engine.detach(effect) }
        engine.detach(trackNode.pannerNode)
        engine.detach(trackNode.outputMixer)
        engine.detach(trackNode.concertHallSend)
        if let send = trackNode.earlyReflectionSend { engine.detach(send) }
        if let effect = trackNode.earlyReflectionNode { engine.detach(effect) }
        
        // Detach plugin nodes
        for auNode in trackNode.pluginNodes {
            engine.disconnectNodeOutput(auNode)
            engine.detach(auNode)
        }
        
        trackNodes.removeValue(forKey: trackID)
    }
    
    /// Update track parameters (volume, pan, mute)
    public func updateTrackParameters(for track: Track) {
        guard let trackNode = trackNodes[track.id] else { return }
        
        trackNode.setVolume(track.volume)
        trackNode.setPan(track.pan)
        trackNode.setMuted(track.isMuted)
        // Keep the acoustic send synchronized with all track edits, including undo/redo.
        setConcertHallDepth(track.stageReverbZone ?? 2, wetTrim: track.stageWetTrim ?? 1, for: track.id)
    }
    
    /// Set Concert Hall ambience according to orchestral stage depth.
    /// Depth 0 = conductor; depth 5 = back row.
    public func setConcertHallDepth(_ depth: Int, wetTrim: Float = 1, for trackID: TrackID) {
        let safeDepth = max(0, min(5, depth))
        let trim = wetTrim.isFinite ? min(2, max(0, wetTrim)) : 1
        trackNodes[trackID]?.setStageAcoustics(
            directLevel: Self.stageDirectLevels[safeDepth],
            hallSendLevel: Self.concertHallSendLevels[safeDepth] * trim,
            zone: safeDepth
        )
    }

    public func setConcertHallOverallReverb(_ level: Float) {
        concertHallOverallReverb = level.isFinite ? min(2, max(0, level)) : 1
        concertHallReturnMixer.outputVolume = concertHallOverallReverb
    }

    /// Switch the single shared hall return to Studio's original algorithmic DSP.
    ///
    /// This is an opt-in prototype. It leaves track sends, the dry signal chain,
    /// stage-depth behavior and the master return unchanged. Graph edits happen
    /// only with the engine stopped; failed restarts restore the previous route.
    /// Call from UI/control code, never from an audio render callback.
    public func setNativeConcertHallReverbEnabled(_ enabled: Bool) throws {
        guard enabled != usesNativeConcertHallReverb else { return }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }

        if enabled && nativeConcertHallReverb == nil {
            NativeRoomReverbAudioUnit.registerIfNeeded()
            let effect = AVAudioUnitEffect(
                audioComponentDescription: NativeRoomReverbAudioUnit.componentDescription
            )
            engine.attach(effect)
            (effect.auAudioUnit as? NativeRoomReverbAudioUnit)?
                .configureDesignedRoom(designedRoom)
            nativeConcertHallReverb = effect
        }

        let previous: AVAudioNode = usesNativeConcertHallReverb
            ? (nativeConcertHallReverb ?? concertHallReverb) : concertHallReverb
        let target: AVAudioNode = enabled
            ? (nativeConcertHallReverb ?? concertHallReverb) : concertHallReverb
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2
        )!

        // Install source-positioned ER only if native room processing is selected.
        if enabled {
            NativeStageEarlyReflectionAudioUnit.registerIfNeeded()
            if !nativeEarlyReflectionMixerConnected {
                nativeEarlyReflectionMixer.outputVolume = 0
                engine.attach(nativeEarlyReflectionMixer)
                engine.connect(nativeEarlyReflectionMixer, to: concertHallReturnMixer,
                               format: format)
                nativeEarlyReflectionMixerConnected = true
            }
            for node in trackNodes.values {
                installStageEarlyReflections(for: node, format: format)
            }
        }

        func route(_ effect: AVAudioNode) {
            engine.disconnectNodeOutput(concertHallSendMixer)
            engine.disconnectNodeOutput(concertHallReverb)
            if let nativeConcertHallReverb {
                engine.disconnectNodeOutput(nativeConcertHallReverb)
            }
            engine.connect(concertHallSendMixer, to: effect, format: format)
            engine.connect(effect, to: concertHallReturnMixer, format: format)
        }

        route(target)
        nativeEarlyReflectionMixer.outputVolume = enabled ? 1 : 0
        do {
            if wasRunning { try engine.start() }
            usesNativeConcertHallReverb = enabled
            for node in trackNodes.values {
                node.setVirtualMicrophone(virtualMicrophoneSettings, nativeEnabled: enabled)
            }
            isRunning = engine.isRunning
        } catch {
            // The original Concert Hall routing is the rollback boundary.
            engine.stop()
            route(previous)
            nativeEarlyReflectionMixer.outputVolume = usesNativeConcertHallReverb ? 1 : 0
            if wasRunning { try? engine.start() }
            isRunning = engine.isRunning
            throw AudioEngineError.failedToStart(underlying: error)
        }
    }

    /// The virtual stereo microphone alters native early reflections and
    /// direct-to-room balance without rebuilding the graph.
    public func setVirtualMicrophone(_ settings: StudioVirtualMicrophoneSettings) {
        let safe = StudioVirtualMicrophoneSettings(
            perspective: settings.perspective, stereoWidth: settings.safeWidth
        )
        virtualMicrophoneSettings = safe
        for node in trackNodes.values {
            node.setVirtualMicrophone(safe, nativeEnabled: usesNativeConcertHallReverb)
        }
    }

    /// Prepare six-band decay and dimension-derived early reflections outside
    /// the audio callback. Graph topology and legacy Apple reverb are unchanged.
    /// Render resources are rebuilt only while AVAudioEngine is stopped.
    public func configureDesignedRoom(_ design: StudioAcousticRoomDesign) throws {
        let oldDesign = designedRoom
        let running = engine.isRunning
        if running { engine.stop() }

        func install(_ settings: StudioAcousticRoomDesign) {
            (nativeConcertHallReverb?.auAudioUnit as? NativeRoomReverbAudioUnit)?
                .configureDesignedRoom(settings)
            for track in trackNodes.values {
                (track.earlyReflectionNode?.auAudioUnit as?
                    NativeStageEarlyReflectionAudioUnit)?.configureDesignedRoom(settings)
            }
        }

        install(design)
        do {
            if running { try engine.start() }
            designedRoom = design
            isRunning = engine.isRunning
        } catch {
            install(oldDesign)
            if running { try? engine.start() }
            isRunning = engine.isRunning
            throw AudioEngineError.failedToStart(underlying: error)
        }
    }

    /// Select a prepared native room by stable identifier. Audio Unit parameters
    /// are applied without rebuilding the graph or allocating on the render thread.
    /// Returns false if the room is unknown; does not modify the saved choice.
    @discardableResult
    public func selectNativeRoomProfile(id: String) -> Bool {
        guard let index = StudioRoomAcousticProfile.index(forID: id) else {
            return false
        }
        selectedNativeRoomProfileID = id
        if let roomParameter = nativeConcertHallReverb?.auAudioUnit.parameterTree?
            .parameter(withAddress: NativeRoomReverbAudioUnit.roomParameterAddress) {
            roomParameter.value = AUValue(index)
        }
        for node in trackNodes.values { node.setNativeRoomProfileIndex(index) }
        return true
    }

    /// One optional wet-only early-reflection Audio Unit per instrument.
    /// Called only with the audio engine stopped, with the dry edges intact.
    private func installStageEarlyReflections(for node: TrackAudioNode,
                                              format: AVAudioFormat) {
        guard node.earlyReflectionNode == nil else { return }
        let send = AVAudioMixerNode()
        let effect = AVAudioUnitEffect(
            audioComponentDescription: NativeStageEarlyReflectionAudioUnit.componentDescription
        )
        engine.attach(send)
        engine.attach(effect)
        (effect.auAudioUnit as? NativeStageEarlyReflectionAudioUnit)?
            .configureDesignedRoom(designedRoom)
        engine.connect(send, to: effect, format: format)
        engine.connect(effect, to: nativeEarlyReflectionMixer, format: format)
        node.installEarlyReflection(send: send, effect: effect)
        node.setVirtualMicrophone(virtualMicrophoneSettings, nativeEnabled: true)
        node.setNativeRoomProfileIndex(
            StudioRoomAcousticProfile.index(forID: selectedNativeRoomProfileID) ?? 0
        )
        engine.connect(node.pannerNode, to: [
            AVAudioConnectionPoint(node: node.outputMixer, bus: 0),
            AVAudioConnectionPoint(node: node.concertHallSend, bus: 0),
            AVAudioConnectionPoint(node: send, bus: 0)
        ], fromBus: 0, format: format)
    }

    /// Get track node for external access
    public func trackNode(for trackID: TrackID) -> TrackAudioNode? {
        trackNodes[trackID]
    }
    
    // MARK: - Solo Management
    
    public func updateSoloState(tracks: [Track]) {
        let hasSoloedTracks = tracks.contains { $0.isSolo }
        
        for track in tracks {
            guard let trackNode = trackNodes[track.id] else { continue }
            
            if hasSoloedTracks {
                // Mute all non-soloed tracks
                trackNode.setMuted(!track.isSolo)
            } else {
                // Respect individual mute states
                trackNode.setMuted(track.isMuted)
            }
        }
    }
    
    // MARK: - Plugin Management
    
    /// Insert an Audio Unit at a slot in a track
    public func insertPlugin(
        _ audioUnit: AVAudioUnit,
        on trackID: TrackID,
        at slotIndex: Int
    ) throws {
        try insertPlugin(audioUnit, at: slotIndex, in: trackID)
    }
    
    /// Insert an Audio Unit at a slot in a track (alternate signature).
    /// Stop the engine for graph changes, as for track creation/removal.
    public func insertPlugin(
        _ audioUnit: AVAudioUnit,
        at slotIndex: Int,
        in trackID: TrackID
    ) throws {
        guard let trackNode = trackNodes[trackID] else {
            throw AudioEngineError.nodeNotFound(trackID)
        }
        guard slotIndex >= 0 && slotIndex <= trackNode.pluginNodes.count else {
            throw AudioEngineError.invalidPluginSlot(slotIndex)
        }

        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        defer {
            if wasRunning && !engine.isRunning {
                do { try engine.start() }
                catch { print("[AudioEngine] Failed to restore engine after insert: \(error)") }
            }
        }
        engine.attach(audioUnit)
        do {
            try rebuildPluginChain(
                for: trackNode, inserting: audioUnit, at: slotIndex
            )
            if wasRunning { try engine.start() }
        } catch {
            // Keep the original graph if the inserted AU cannot be connected.
            trackNode.pluginNodes.removeAll { $0 === audioUnit }
            engine.disconnectNodeOutput(audioUnit)
            engine.detach(audioUnit)
            try? rebuildPluginChain(for: trackNode)
            throw error
        }
    }

    /// Remove an insert effect, preserving the other slots and hall send.
    public func removePlugin(at slotIndex: Int, from trackID: TrackID) throws {
        guard let trackNode = trackNodes[trackID] else {
            throw AudioEngineError.nodeNotFound(trackID)
        }
        guard trackNode.pluginNodes.indices.contains(slotIndex) else {
            throw AudioEngineError.invalidPluginSlot(slotIndex)
        }

        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        defer {
            if wasRunning && !engine.isRunning {
                do { try engine.start() }
                catch { print("[AudioEngine] Failed to restore engine after remove: \(error)") }
            }
        }

        let oldNode = trackNode.pluginNodes.remove(at: slotIndex)
        engine.disconnectNodeOutput(oldNode)
        var detached = false
        do {
            try rebuildPluginChain(for: trackNode)
            // Detach only while stopped; never mutate the live graph.
            engine.detach(oldNode)
            detached = true
            if wasRunning { try engine.start() }
        } catch {
            if detached { engine.attach(oldNode) }
            trackNode.pluginNodes.insert(oldNode, at: slotIndex)
            try? rebuildPluginChain(for: trackNode)
            throw error
        }
    }

    /// Number of currently hosted insert effects, independent of placeholder
    /// slots in the project model. Used to keep insert order and persisted
    /// slot indices aligned with the actual audio graph.
    public func pluginCount(on trackID: TrackID) -> Int {
        trackNodes[trackID]?.pluginNodes.count ?? 0
    }

    /// Return the actual effect Audio Unit connected at a track's insert slot.
    /// Read-only: does not rebuild or otherwise modify the audio graph.
    public func pluginNode(on trackID: TrackID, at slotIndex: Int) -> AVAudioUnit? {
        guard let trackNode = trackNodes[trackID],
              trackNode.pluginNodes.indices.contains(slotIndex) else { return nil }
        return trackNode.pluginNodes[slotIndex]
    }

    private func rebuildPluginChain(
        for trackNode: TrackAudioNode,
        inserting newPlugin: AVAudioUnit? = nil,
        at insertIndex: Int? = nil
    ) throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        )!
        
        // Insert new plugin if provided
        if let plugin = newPlugin, let index = insertIndex {
            trackNode.pluginNodes.insert(plugin, at: min(index, trackNode.pluginNodes.count))
        }
        
        // Disconnect existing chain
        engine.disconnectNodeOutput(trackNode.inputMixer)
        for auNode in trackNode.pluginNodes {
            engine.disconnectNodeOutput(auNode)
        }
        
        // Rebuild chain: input -> [plugins] -> gain -> panner -> output
        var previousNode: AVAudioNode = trackNode.inputMixer
        
        for auNode in trackNode.pluginNodes {
            engine.connect(previousNode, to: auNode, format: format)
            previousNode = auNode
        }
        
        engine.connect(previousNode, to: trackNode.gainNode, format: format)
        if let effect = trackNode.stereoPositionNode {
            engine.connect(trackNode.gainNode, to: effect, format: format)
            engine.connect(effect, to: trackNode.pannerNode, format: format)
        } else {
            engine.connect(trackNode.gainNode, to: trackNode.pannerNode, format: format)
        }
        // Rebuilding an insert chain must preserve the same post-panner
        // dry / Concert Hall split established when the track was created.
        // Connecting only to outputMixer previously disconnected its wet send.
        engine.connect(
            trackNode.pannerNode,
            to: [
                AVAudioConnectionPoint(node: trackNode.outputMixer, bus: 0),
                AVAudioConnectionPoint(node: trackNode.concertHallSend, bus: 0)
            ],
            fromBus: 0,
            format: format
        )
    }

    // MARK: - Audio Playback
    
    /// Schedule audio file playback on a track
    public func scheduleAudioFile(
        _ file: AVAudioFile,
        on trackID: TrackID,
        at sampleTime: Int64,
        startingFrame: AVAudioFramePosition = 0,
        frameCount: AVAudioFrameCount? = nil
    ) throws {
        guard let trackNode = trackNodes[trackID] else {
            throw AudioEngineError.nodeNotFound(trackID)
        }
        
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        
        let format = file.processingFormat
        engine.connect(playerNode, to: trackNode.inputMixer, format: format)
        
        // Calculate frames to play
        let totalFrames = AVAudioFrameCount(file.length - startingFrame)
        let framesToPlay = frameCount ?? totalFrames
        
        // Schedule the file
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: framesToPlay,
            at: nil
        )
        
        trackNode.playerNodes.append(playerNode)
    }
    
    /// Start playback from a specific sample position
    public func startPlayback(from samplePosition: Int64) {
        playbackStartSamplePosition = samplePosition
        currentSamplePosition = samplePosition
        realtimeSamplePosition.publish(samplePosition)
        playbackStartHostTime = mach_absolute_time()
        isPlaying = true
        
        // Install timing tap if not already installed
        installTimingTap()
        
        // Start all player nodes
        for trackNode in trackNodes.values {
            for playerNode in trackNode.playerNodes {
                playerNode.play()
            }
        }
        
        print("[AudioEngine] Started playback from sample \(samplePosition)")
    }
    
    /// Stop playback
    public func stopPlayback() {
        isPlaying = false
        
        // Stop all player nodes
        for trackNode in trackNodes.values {
            for playerNode in trackNode.playerNodes {
                playerNode.stop()
            }
            trackNode.playerNodes.removeAll()
        }
        
        print("[AudioEngine] Stopped playback at sample \(currentSamplePosition)")
    }
    
    /// Set the current sample position (for seeking)
    public func setSamplePosition(_ position: Int64) {
        currentSamplePosition = position
        realtimeSamplePosition.publish(position)
        playbackStartSamplePosition = position
        playbackStartHostTime = mach_absolute_time()
        samplePositionSubject.send(position)
    }
    
    // MARK: - Timing Tap
    
    /// Install a tap on the main mixer to track sample position and trigger MIDI events
    private func installTimingTap() {
        guard !timingTapInstalled else { return }
        
        let format = masterMixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            print("[AudioEngine] Cannot install timing tap - invalid format")
            return
        }
        
        // Update our sample rate
        sampleRate = format.sampleRate
        
        // Keep the MIDI clock calculation unchanged. UI receives only a
        // lock-free position snapshot, not a new Task for every buffer.
        let publishedPosition = realtimeSamplePosition
        masterMixer.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isPlaying else { return }
            
            // Calculate current sample position based on elapsed time
            let currentHostTime = mach_absolute_time()
            let elapsedSamples = self.hostTimeToSamples(from: self.playbackStartHostTime, to: currentHostTime)
            let bufferStartSample = self.playbackStartSamplePosition + elapsedSamples
            
            // Call MIDI event callback with sample-accurate timing
            // This processes MIDI events that fall within this buffer window
            self.midiEventCallback?(bufferStartSample, buffer.frameLength, self.currentTempo)
            
            // Constant-time render callback publication, no actor hop.
            publishedPosition.publish(bufferStartSample + Int64(buffer.frameLength))
        }
        
        timingPositionUITimer?.invalidate()
        timingPositionUITimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 30.0, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                let position = self.realtimeSamplePosition.load()
                self.currentSamplePosition = position
                self.samplePositionSubject.send(position)
            }
        }
        timingTapInstalled = true
        print("[AudioEngine] Timing tap installed, sample rate: \(sampleRate), buffer size: \(bufferSize)")
    }
    
    /// Set the buffer size (requires engine restart)
    public func setBufferSize(_ newSize: AVAudioFrameCount) {
        guard Self.availableBufferSizes.contains(newSize) else {
            print("[AudioEngine] Invalid buffer size: \(newSize)")
            return
        }
        
        let wasRunning = isRunning
        let wasPlaying = isPlaying
        
        // Stop everything
        if wasPlaying { stopPlayback() }
        if wasRunning { stop() }
        
        // Remove existing tap
        removeTimingTap()
        
        // Update buffer size
        bufferSize = newSize
        
        // Restart
        if wasRunning {
            try? start()
        }
        if wasPlaying {
            startPlayback(from: currentSamplePosition)
        }
        
        print("[AudioEngine] Buffer size changed to \(newSize) samples (~\(String(format: "%.1f", Double(newSize) / sampleRate * 1000))ms latency)")
    }
    
    /// Get the current latency in milliseconds
    public var latencyMs: Double {
        Double(bufferSize) / sampleRate * 1000.0
    }
    
    /// Get supported sample rates from the audio device
    public func getSupportedSampleRates() -> [Double] {
        // For now return common rates - could query hardware in future
        return Self.availableSampleRates.filter { $0 <= 96000 }
    }
    
    /// Remove the timing tap
    public func removeTimingTap() {
        guard timingTapInstalled else { return }
        masterMixer.removeTap(onBus: 0)
        timingPositionUITimer?.invalidate()
        timingPositionUITimer = nil
        timingTapInstalled = false
    }
    
    /// Convert host time difference to samples
    private func hostTimeToSamples(from startTime: UInt64, to endTime: UInt64) -> Int64 {
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        
        let elapsedHostTime = endTime - startTime
        let elapsedNanos = Double(elapsedHostTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
        let elapsedSeconds = elapsedNanos / 1_000_000_000.0
        
        return Int64(elapsedSeconds * sampleRate)
    }
    
    /// Convert a host time to sample position relative to playback start
    public func hostTimeToSamplePosition(_ hostTime: UInt64) -> Int64 {
        guard hostTime >= playbackStartHostTime else {
            return playbackStartSamplePosition
        }
        let elapsedSamples = hostTimeToSamples(from: playbackStartHostTime, to: hostTime)
        return playbackStartSamplePosition + elapsedSamples
    }
    
    /// Get the current sample position (thread-safe read)
    public func getCurrentSamplePosition() -> Int64 {
        return currentSamplePosition
    }
    
    // MARK: - Master Output
    
    public var masterVolume: Float {
        get { masterMixer.outputVolume }
        set { masterMixer.outputVolume = newValue }
    }
    
    public func setMasterVolume(_ volume: Float) {
        masterMixer.outputVolume = volume
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }
    
    @objc private func handleConfigurationChange(_ notification: Notification) {
        // Handle audio configuration changes (e.g., sample rate change)
        Task { @MainActor in
            sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            
            if isRunning {
                try? start()
            }
        }
    }
    
    // MARK: - Metronome Control
    
    private var metronomePlayerNode: AVAudioPlayerNode?
    private var normalClickBuffer: AVAudioPCMBuffer?
    private var accentClickBuffer: AVAudioPCMBuffer?
    private var metronomeEnabled: Bool = false
    
    /// Enable or disable the metronome
    public func setMetronomeEnabled(_ enabled: Bool) {
        metronomeEnabled = enabled
        
        if enabled && metronomePlayerNode == nil {
            setupMetronomePlayer()
        }
        
        print("[AudioEngine] Metronome enabled: \(enabled)")
    }
    
    /// Set up the metronome player node and click buffers
    private func setupMetronomePlayer() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        // Create a single clean click buffer - same sound every beat
        normalClickBuffer = createClickBuffer(format: format)
        accentClickBuffer = normalClickBuffer  // Same click for both
        
        // Create player node
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: masterMixer, format: format)
        
        metronomePlayerNode = player
        player.play()
        
        print("[AudioEngine] Metronome player set up")
    }
    
    /// Create a clean, simple click buffer
    private func createClickBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Short, punchy click - 8ms duration
        let duration = 0.008
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        
        guard let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return nil }
        
        // Clean click: 880Hz (A5) with very fast decay
        let frequency = 880.0
        let volume: Float = 0.75
        
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = Float(exp(-t * 300))  // Very fast decay for sharp click
            let sample = Float(sin(2.0 * .pi * frequency * t)) * envelope * volume
            leftChannel[i] = sample
            rightChannel[i] = sample
        }
        
        return buffer
    }
    
    /// Play a metronome click immediately
    public func playMetronomeClick(isDownbeat: Bool) {
        guard metronomeEnabled,
              let player = metronomePlayerNode,
              let buffer = normalClickBuffer else { return }  // Always use same click - no accent
        
        // Schedule the click to play immediately
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
    
    /// Set metronome volume (0.0 - 1.0)
    public func setMetronomeVolume(_ volume: Float) {
        metronomeNode?.volume = volume
    }
    
    /// Generate a metronome click (call from timing callback) - legacy method
    public func generateMetronomeClick(buffer: AVAudioPCMBuffer, isDownbeat: Bool) {
        metronomeNode?.generateClick(buffer: buffer, isDownbeat: isDownbeat)
    }
    
    // MARK: - Metering
    
    /// Install a tap on the master output for metering
    public func installMasterMeter(
        bufferSize: AVAudioFrameCount = 1024,
        handler: @escaping (Float, Float) -> Void  // (leftPeak, rightPeak)
    ) {
        let format = masterMixer.outputFormat(forBus: 0)
        
        masterMixer.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: format
        ) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            
            var leftPeak: Float = 0
            var rightPeak: Float = 0
            
            if channelCount >= 1 {
                for i in 0..<frameLength {
                    leftPeak = max(leftPeak, abs(channelData[0][i]))
                }
            }
            
            if channelCount >= 2 {
                for i in 0..<frameLength {
                    rightPeak = max(rightPeak, abs(channelData[1][i]))
                }
            } else {
                rightPeak = leftPeak
            }
            
            handler(leftPeak, rightPeak)
        }
    }
    
    public func removeMasterMeter() {
        masterMixer.removeTap(onBus: 0)
    }
}

// MARK: - Track Audio Node

/// Represents the audio node chain for a single track
public final class TrackAudioNode {
    public let trackID: TrackID
    
    // Node chain: input -> [plugins] -> gain -> panner -> output
    public let inputMixer: AVAudioMixerNode
    public let gainNode: AVAudioMixerNode
    public let pannerNode: AVAudioMixerNode
    public var stereoPositionNode: AVAudioUnitEffect?
    public let outputMixer: AVAudioMixerNode
    public let concertHallSend: AVAudioMixerNode
    public private(set) var earlyReflectionSend: AVAudioMixerNode?
    public private(set) var earlyReflectionNode: AVAudioUnitEffect?
    private var stagePan: Float = 0
    private var stageZone = 2
    private var nativeMicrophoneDirectGain: Float = 1
    
    // Plugin chain (Audio Units)
    public var pluginNodes: [AVAudioUnit] = []
    
    // Player nodes for audio clips
    public var playerNodes: [AVAudioPlayerNode] = []
    
    // Sampler for MIDI playback
    public var samplerNode: AVAudioUnitSampler?
    
    private var isMuted: Bool = false
    private var volume: Float = 1.0
    private var concertHallSendLevel: Float = 0.20
    private var stageDirectLevel: Float = 1.0

    public init(trackID: TrackID, channelCount: Int, sampleRate: Double) {
        self.trackID = trackID
        self.inputMixer = AVAudioMixerNode()
        self.gainNode = AVAudioMixerNode()
        self.pannerNode = AVAudioMixerNode()
        self.outputMixer = AVAudioMixerNode()
        self.concertHallSend = AVAudioMixerNode()
        self.concertHallSend.outputVolume = 0.20
    }
    
    public func setVolume(_ volume: Float) {
        self.volume = volume
        updateOutputVolume()
    }

    /// Apply distance-dependent direct level and room send together.
    /// This does not change the user's saved track volume.
    public func setStageAcoustics(directLevel: Float, hallSendLevel: Float,
                                  zone: Int = 2) {
        stageDirectLevel = directLevel.isFinite ? min(1, max(0, directLevel)) : 1
        concertHallSendLevel = hallSendLevel.isFinite ? max(0, hallSendLevel) : 0
        stageZone = min(5, max(0, zone))
        earlyReflectionNode?.auAudioUnit.parameterTree?
            .parameter(withAddress: NativeStageEarlyReflectionAudioUnit.zoneAddress)?
            .value = AUValue(stageZone)
        updateOutputVolume()
    }

    public func installEarlyReflection(send: AVAudioMixerNode,
                                       effect: AVAudioUnitEffect) {
        earlyReflectionSend = send
        earlyReflectionNode = effect
        setPan(stagePan)
        setStageAcoustics(directLevel: stageDirectLevel,
                         hallSendLevel: concertHallSendLevel, zone: stageZone)
    }

    public func setNativeRoomProfileIndex(_ index: Int) {
        earlyReflectionNode?.auAudioUnit.parameterTree?
            .parameter(withAddress: NativeStageEarlyReflectionAudioUnit.roomAddress)?
            .value = AUValue(index)
    }

    public func setVirtualMicrophone(_ settings: StudioVirtualMicrophoneSettings,
                                     nativeEnabled: Bool) {
        earlyReflectionNode?.auAudioUnit.parameterTree?
            .parameter(withAddress: NativeStageEarlyReflectionAudioUnit.microphoneAddress)?
            .value = AUValue(settings.perspective.parameterIndex)
        earlyReflectionNode?.auAudioUnit.parameterTree?
            .parameter(withAddress: NativeStageEarlyReflectionAudioUnit.microphoneWidthAddress)?
            .value = settings.safeWidth
        nativeMicrophoneDirectGain = nativeEnabled ? settings.perspective.directLevel : 1
        updateOutputVolume()
    }
    
    public func setPan(_ pan: Float) {
        stagePan = pan.isFinite ? min(1, max(-1, pan)) : 0
        earlyReflectionNode?.auAudioUnit.parameterTree?
            .parameter(withAddress: NativeStageEarlyReflectionAudioUnit.panAddress)?
            .value = stagePan
        if let parameter = stereoPositionNode?.auAudioUnit.parameterTree?.parameter(withAddress: 0) {
            // The mixer must remain centered: otherwise its stereo balance
            // would undo the processor's stereo-preserving position.
            pannerNode.pan = 0
            parameter.value = pan.isFinite ? min(1, max(-1, pan)) : 0
        } else {
            pannerNode.pan = pan
        }
    }
    
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
        updateOutputVolume()
    }
    
    private func updateOutputVolume() {
        let dryGain: Float = isMuted ? 0.0 : volume
        outputMixer.outputVolume = dryGain * stageDirectLevel * nativeMicrophoneDirectGain
        // The hall send branches before outputMixer, so it must explicitly
        // follow volume and mute (including solo) to prevent wet-only audio.
        // Keep the room send separate from direct-sound distance attenuation.
        concertHallSend.outputVolume = dryGain * concertHallSendLevel
        earlyReflectionSend?.outputVolume = dryGain * concertHallSendLevel
    }
}

// MARK: - Metronome Node

/// Simple metronome using an oscillator
public final class MetronomeNode {
    private let sampleRate: Double
    
    public var volume: Float = 0.8
    public var isEnabled: Bool = false
    
    // Pre-generated click buffers for efficiency
    private var normalClick: [Float] = []
    private var accentClick: [Float] = []
    
    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        generateClickBuffers()
    }
    
    /// Pre-generate clean click sounds
    private func generateClickBuffers() {
        // Simple, short click - 10ms duration
        let duration = 0.010
        let samples = Int(duration * sampleRate)
        
        // Normal click: 1000 Hz
        normalClick = [Float](repeating: 0, count: samples)
        for i in 0..<samples {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 200)  // Fast decay
            normalClick[i] = Float(sin(2.0 * .pi * 1000.0 * t) * envelope)
        }
        
        // Accent click: 1500 Hz, slightly louder
        accentClick = [Float](repeating: 0, count: samples)
        for i in 0..<samples {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 150)  // Slightly slower decay for accent
            accentClick[i] = Float(sin(2.0 * .pi * 1500.0 * t) * envelope * 1.2)
        }
    }
    
    /// Generate a click at the current sample position
    public func generateClick(
        buffer: AVAudioPCMBuffer,
        isDownbeat: Bool
    ) {
        guard isEnabled else { return }
        
        let clickData = isDownbeat ? accentClick : normalClick
        guard let channelData = buffer.floatChannelData else { return }
        
        let samplesToWrite = min(clickData.count, Int(buffer.frameLength))
        
        for i in 0..<samplesToWrite {
            let sample = clickData[i] * volume
            channelData[0][i] += sample
            if buffer.format.channelCount > 1 {
                channelData[1][i] += sample
            }
        }
    }
}
