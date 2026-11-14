import Foundation
import AudioToolbox
import AVFoundation
import DAWRealtime

// MARK: - Render Graph

/// Manages the audio processing graph for all tracks
/// Handles plugin hosting, track mixing, and audio rendering
public final class RenderGraph {
    
    // MARK: - Track Node
    
    /// Owns preallocated per-track scratch. Released by ARC off the render
    /// callback only after every snapshot borrowing the route has retired.
    final class TrackScratchBuffers {
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        let frameCapacity: Int

        init(frameCapacity: Int) {
            self.frameCapacity = frameCapacity
            left = .allocate(capacity: frameCapacity)
            right = .allocate(capacity: frameCapacity)
            left.initialize(repeating: 0, count: frameCapacity)
            right.initialize(repeating: 0, count: frameCapacity)
        }

        deinit {
            left.deinitialize(count: frameCapacity)
            right.deinitialize(count: frameCapacity)
            left.deallocate()
            right.deallocate()
        }
    }

    /// Exact single owner of a raw (non-AVAudioUnit-hosted) effect handle.
    /// Snapshot-held tracks retain this owner until render readers finish.
    final class EffectLifetime {
        let unit: AudioUnit
        init(_ unit: AudioUnit) { self.unit = unit }
        deinit { AudioComponentInstanceDispose(unit) }
    }

    /// Immutable processing bundle for a particular published route generation.
    /// The AVAudioUnit wrapper owns the underlying instrument AudioUnit; raw
    /// effects use EffectLifetime and buffers use TrackScratchBuffers. Old
    /// bundles remain retained by retired render snapshots until readers exit.
    final class ProcessingResources {
        let instrumentOwner: AVAudioUnit?
        let instrumentUnit: AudioUnit?
        let auAudioUnit: AUAudioUnit?
        let renderBlock: AURenderBlock?
        let effects: [EffectLifetime?]
        let scratch: TrackScratchBuffers

        init(instrumentOwner: AVAudioUnit? = nil,
             instrumentUnit: AudioUnit? = nil,
             auAudioUnit: AUAudioUnit? = nil,
             renderBlock: AURenderBlock? = nil,
             effects: [EffectLifetime?] = [],
             scratch: TrackScratchBuffers) {
            self.instrumentOwner = instrumentOwner
            self.instrumentUnit = instrumentUnit
            self.auAudioUnit = auAudioUnit
            self.renderBlock = renderBlock
            self.effects = effects
            self.scratch = scratch
        }

        var isEmpty: Bool {
            instrumentUnit == nil && effects.allSatisfy { $0 == nil }
        }
    }

    /// Shared gain/pan/mute controls are written solely by the render callback
    /// while output runs (or by control after output has drained).
    final class TrackControls {
        var volume: Float = 1.0
        var pan: Float = 0.0
        var isMuted: Bool = false
        var isSolo: Bool = false
    }

    final class TrackNode {
        let id: TrackID
        let controls = TrackControls()
        var pendingInstrumentRequestID: UInt64 = 0
        var processing: ProcessingResources

        init(id: TrackID, bufferSize: Int) {
            self.id = id
            self.processing = ProcessingResources(
                scratch: TrackScratchBuffers(frameCapacity: bufferSize)
            )
        }
        var isEmpty: Bool { processing.isEmpty }
    }

    /// Every published route captures its processing bundle by strong
    /// reference, independent of later control-side track reconfiguration.
    private struct RenderRoute {
        let id: TrackID
        let controls: TrackControls
        let processing: ProcessingResources
    }

    // MARK: - Properties
    
    private var tracks: [TrackID: TrackNode] = [:]
    private var nextInstrumentRequestID: UInt64 = 0
    /// Route membership and processing resources are captured per generation.
    /// TrackControls remain shared, with writes owned by the render domain.
    private final class RenderSnapshot {
        let generation: UInt64
        let routes: [RenderRoute]
        let byID: [TrackID: RenderRoute]
        let hasSoloedTracks: Bool
        init(generation: UInt64, routes: [RenderRoute]) {
            self.generation = generation
            self.routes = routes
            self.byID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
            self.hasSoloedTracks = routes.contains { $0.controls.isSolo }
        }
    }

    /// The C11 exchange owns the current opaque snapshot pointer. The
    /// control side keeps replaced objects until every reader is quiescent.
    /// ARC releases MUST NEVER run on the audio callback.
    private let routeExchange: OpaquePointer
    private var latestSnapshot: RenderSnapshot
    private var retiredSnapshots: [UnsafeMutableRawPointer] = []

    private func publishRenderSnapshot() {
        let routes = tracks.values.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }.map {
            RenderRoute(id: $0.id, controls: $0.controls, processing: $0.processing)
        }
        let next = RenderSnapshot(
            generation: latestSnapshot.generation &+ 1, routes: routes
        )
        let owned = Unmanaged.passRetained(next).toOpaque()
        guard let old = daw_route_exchange_publish(routeExchange, owned) else {
            Unmanaged<RenderSnapshot>.fromOpaque(owned).release()
            preconditionFailure("Render route exchange lost its active snapshot")
        }
        latestSnapshot = next
        retiredSnapshots.append(old)
        retireQuiescentSnapshots()
    }

    /// Only on the serialized control domain. Releasing a route snapshot may
    /// release AVAudioUnit references, so never call from the callback.
    private func retireQuiescentSnapshots() {
        guard daw_route_exchange_is_quiescent(routeExchange) else { return }
        for raw in retiredSnapshots {
            Unmanaged<RenderSnapshot>.fromOpaque(raw).release()
        }
        retiredSnapshots.removeAll(keepingCapacity: true)
    }

    /// Control-domain-only count, used to bound deferred snapshot retention.
    /// If this reaches the cap, the backend briefly drains callbacks before
    /// publishing more routes. Reclamation must never run on the callback.
    var pendingRouteRetirementCount: Int { retiredSnapshots.count }

    func reclaimRetiredRoutesWhileQuiescent() {
        retireQuiescentSnapshots()
    }

    private func withRenderSnapshot<T>(_ body: (RenderSnapshot) -> T) -> T {
        guard let raw = daw_route_exchange_begin_read(routeExchange) else {
            preconditionFailure("No render snapshot published")
        }
        defer { daw_route_exchange_end_read(routeExchange) }
        let snapshot = Unmanaged<RenderSnapshot>.fromOpaque(raw).takeUnretainedValue()
        return body(snapshot)
    }

    /// One output render frame at a time. An unexpected overlapping callback
    /// leaves its already-cleared destination silent rather than invoking a
    /// shared legacy effect/AU concurrently. This never blocks or spins.
    private func withRenderFrame(_ body: (RenderSnapshot) -> Void) {
        guard daw_route_exchange_try_enter_render(routeExchange) else { return }
        defer { daw_route_exchange_leave_render(routeExchange) }
        withRenderSnapshot(body)
    }


    var renderSnapshotGeneration: UInt64 { latestSnapshot.generation }
    var renderSnapshotTrackIDs: [TrackID] { latestSnapshot.routes.map(\.id) }
    /// Test-only/introspection identity of the immutable resources retained
    /// by the last published graph generation, not the mutable track table.
    func publishedProcessingIdentity(for id: TrackID) -> ObjectIdentifier? {
        latestSnapshot.byID[id].map { ObjectIdentifier($0.processing) }
    }
    func publishedScratchCapacity(for id: TrackID) -> Int? {
        latestSnapshot.byID[id]?.processing.scratch.frameCapacity
    }


    private var masterVolume: Float = 1.0
    private let sampleRate: Double
    private var bufferSize: Int
    
    // MARK: - Initialization
    
    init(sampleRate: Double, bufferSize: Int) {
        let empty = RenderSnapshot(generation: 0, routes: [])
        let owned = Unmanaged.passRetained(empty).toOpaque()
        guard let exchange = daw_route_exchange_create(owned) else {
            Unmanaged<RenderSnapshot>.fromOpaque(owned).release()
            preconditionFailure("Unable to allocate native render route exchange")
        }
        self.routeExchange = exchange
        self.latestSnapshot = empty
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
    }
    
    deinit {
        // The backend must first drain hardware output and offline bounce.
        precondition(daw_route_exchange_is_quiescent(routeExchange),
                     "RenderGraph destroyed while an audio render is active")
        guard let active = daw_route_exchange_take_current_quiescent(routeExchange) else {
            preconditionFailure("RenderGraph destroyed without its active snapshot")
        }
        Unmanaged<RenderSnapshot>.fromOpaque(active).release()
        for raw in retiredSnapshots {
            Unmanaged<RenderSnapshot>.fromOpaque(raw).release()
        }
        daw_route_exchange_destroy(routeExchange)
        // Track scratch/effects/AVAudioUnit owners are released by ARC after
        // every published snapshot has been reclaimed on this control thread.
    }
    
    // MARK: - Configuration
    
    /// Only after hardware callbacks and offline bounce are quiescent.
    func setBufferSize(_ size: Int) {
        guard size > 0 else { return }
        bufferSize = size
        for track in tracks.values {
            let old = track.processing
            track.processing = ProcessingResources(
                instrumentOwner: old.instrumentOwner,
                instrumentUnit: old.instrumentUnit,
                auAudioUnit: old.auAudioUnit,
                renderBlock: old.renderBlock,
                effects: old.effects,
                scratch: TrackScratchBuffers(frameCapacity: size)
            )
        }
        publishRenderSnapshot()
    }

    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
    }
    
    // MARK: - Track Management
    
    func createTrack(id: TrackID) {
        guard tracks[id] == nil else { return }
        tracks[id] = TrackNode(id: id, bufferSize: bufferSize)
        publishRenderSnapshot()
        print("[RenderGraph] Created track \\(id.rawValue)")
    }

    /// A retired snapshot retains its immutable ProcessingResources even after
    /// the control dictionary releases the track.
    func removeTrack(id: TrackID) {
        guard tracks.removeValue(forKey: id) != nil else { return }
        publishRenderSnapshot()
        print("[RenderGraph] Removed track \\(id.rawValue)")
    }

    /// Empty tracks can be removed while render snapshots are active:
    /// no AU process resource is shared by an old and new render callback.
    /// Nonempty routes still require the backend's hardware drain.
    func canRemoveEmptyTrackLive(id: TrackID) -> Bool {
        tracks[id]?.isEmpty ?? false
    }

    func setTrackVolume(_ volume: Float, for trackID: TrackID) {
        withRenderSnapshot { $0.byID[trackID]?.controls.volume = volume }
    }
    
    func setTrackPan(_ pan: Float, for trackID: TrackID) {
        withRenderSnapshot { $0.byID[trackID]?.controls.pan = pan }
    }
    
    func setTrackMute(_ muted: Bool, for trackID: TrackID) {
        withRenderSnapshot { $0.byID[trackID]?.controls.isMuted = muted }
    }
    
    /// Solo mutation still requires a drained callback until route-control
    /// parameters have an independent atomic state per graph generation.
    func setTrackSolo(_ solo: Bool, for trackID: TrackID) {
        guard let track = tracks[trackID] else { return }
        track.controls.isSolo = solo
        publishRenderSnapshot()
    }
    
    // MARK: - Plugin Loading
    
    /// Prepared off the active graph, so asynchronous plugin instantiation and
    /// render-resource setup do not hold the hardware output stopped.
    struct PreparedInstrument {
        let owner: AVAudioUnit
        let unit: AudioUnit
        let auAudioUnit: AUAudioUnit
        let renderBlock: AURenderBlock
    }

    /// Owns a newly initialized effect until install or explicit cleanup.
    /// Effect creation never touches the active track graph.
    final class PreparedEffect {
        private(set) var unit: AudioUnit?
        init(unit: AudioUnit) { self.unit = unit }
        func takeUnit() -> AudioUnit? {
            let result = unit
            unit = nil
            return result
        }
        deinit {
            if let unit { AudioComponentInstanceDispose(unit) }
        }
    }

    func prepareInstrument(_ description: AudioComponentDescription, maximumFrames: UInt32) async throws -> PreparedInstrument {
        let avAudioUnit = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AVAudioUnit, Error>) in
            AVAudioUnit.instantiate(with: description, options: []) { avUnit, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let avUnit {
                    continuation.resume(returning: avUnit)
                } else {
                    continuation.resume(throwing: AudioBackendError.pluginLoadFailed("Unknown error"))
                }
            }
        }

        let unit = avAudioUnit.audioUnit
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let status = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
            0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw AudioBackendError.pluginLoadFailed("Instrument stream format failed: \(status)")
        }
        var maxFrames = maximumFrames
        let maxStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
            0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)
        )
        guard maxStatus == noErr else {
            throw AudioBackendError.pluginLoadFailed("Instrument slice limit failed: \(maxStatus)")
        }
        let auAudioUnit = avAudioUnit.auAudioUnit
        try auAudioUnit.allocateRenderResources()
        return PreparedInstrument(
            owner: avAudioUnit, unit: unit,
            auAudioUnit: auAudioUnit, renderBlock: auAudioUnit.renderBlock
        )
    }

    /// Control-serialized request tickets prevent slow async plugin loads
    /// from replacing a newer instrument or a recreated track with the same ID.
    func beginInstrumentReplacement(for trackID: TrackID) throws -> UInt64 {
        guard let track = tracks[trackID] else {
            throw AudioBackendError.trackNotFound(trackID)
        }
        nextInstrumentRequestID &+= 1
        if nextInstrumentRequestID == 0 { nextInstrumentRequestID = 1 }
        track.pendingInstrumentRequestID = nextInstrumentRequestID
        return nextInstrumentRequestID
    }

    func validateInstrumentReplacement(for trackID: TrackID, requestID: UInt64) throws {
        guard let track = tracks[trackID] else {
            throw AudioBackendError.trackNotFound(trackID)
        }
        guard requestID != 0, track.pendingInstrumentRequestID == requestID else {
            throw AudioBackendError.configurationError(
                "Instrument request superseded by a newer load or unload"
            )
        }
    }

    /// Prepared instruments have separate AU instances and scratch buffers.
    /// Publication is control-thread-only, and no hardware drain is needed
    /// when the render callback pins a single immutable route generation.
    /// Call only after the output callback is fully drained.
    /// The old AVAudioUnit remains retained until this synchronous swap.
    func installInstrument(_ prepared: PreparedInstrument, for trackID: TrackID,
                           expectedRequestID: UInt64? = nil) throws -> AudioUnit {
        guard let track = tracks[trackID] else {
            throw AudioBackendError.trackNotFound(trackID)
        }
        if let request = expectedRequestID {
            try validateInstrumentReplacement(for: trackID, requestID: request)
        }
        let previous = track.processing
        track.processing = ProcessingResources(
            instrumentOwner: prepared.owner,
            instrumentUnit: prepared.unit,
            auAudioUnit: prepared.auAudioUnit,
            renderBlock: prepared.renderBlock,
            effects: previous.effects,
            scratch: TrackScratchBuffers(frameCapacity: bufferSize)
        )
        publishRenderSnapshot()
        track.pendingInstrumentRequestID = 0
        return prepared.unit
    }

    /// Convenience method for non-running graph usage. The backend calls the
    /// two stages separately to minimize hardware disruption.
    func loadInstrument(_ description: AudioComponentDescription, for trackID: TrackID) async throws -> AudioUnit {
        let request = try beginInstrumentReplacement(for: trackID)
        let prepared = try await prepareInstrument(description, maximumFrames: UInt32(bufferSize))
        return try installInstrument(prepared, for: trackID, expectedRequestID: request)
    }

    func prepareEffect(_ description: AudioComponentDescription) throws -> PreparedEffect {
        var desc = description
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioBackendError.pluginLoadFailed("Effect component not found")
        }
        var audioUnit: AudioComponentInstance?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        guard status == noErr, let unit = audioUnit else {
            throw AudioBackendError.pluginLoadFailed("Failed to instantiate effect: \(status)")
        }
        let prepared = PreparedEffect(unit: unit)
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let inputStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
            0, &streamFormat, formatSize
        )
        let outputStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
            0, &streamFormat, formatSize
        )
        guard inputStatus == noErr && outputStatus == noErr else {
            throw AudioBackendError.pluginLoadFailed("Effect format configuration failed")
        }
        let initializeStatus = AudioUnitInitialize(unit)
        guard initializeStatus == noErr else {
            throw AudioBackendError.pluginLoadFailed("Effect initialization failed: \(initializeStatus)")
        }
        return prepared
    }

    /// Call only after the output callback is fully drained. The prepared
    /// effect owns cleanup automatically if the track was removed meanwhile.
    func installEffect(_ prepared: PreparedEffect, for trackID: TrackID, slot: Int) throws -> AudioUnit {
        guard let track = tracks[trackID] else {
            throw AudioBackendError.trackNotFound(trackID)
        }
        guard (0..<64).contains(slot) else {
            throw AudioBackendError.configurationError("Effect slot must be between 0 and 63")
        }
        guard let unit = prepared.takeUnit() else {
            throw AudioBackendError.configurationError("Effect was already installed")
        }
        let previous = track.processing
        var effects = previous.effects
        while effects.count <= slot { effects.append(nil) }
        effects[slot] = EffectLifetime(unit)
        track.processing = ProcessingResources(
            instrumentOwner: previous.instrumentOwner,
            instrumentUnit: previous.instrumentUnit,
            auAudioUnit: previous.auAudioUnit,
            renderBlock: previous.renderBlock,
            effects: effects,
            scratch: TrackScratchBuffers(frameCapacity: bufferSize)
        )
        publishRenderSnapshot()
        return unit
    }

    func loadEffect(_ description: AudioComponentDescription, for trackID: TrackID, slot: Int) async throws -> AudioUnit {
        let prepared = try prepareEffect(description)
        return try installEffect(prepared, for: trackID, slot: slot)
    }

    func unloadPlugin(for trackID: TrackID, slot: Int) {
        guard let track = tracks[trackID] else { return }
        let old = track.processing
        var effects = old.effects
        var owner = old.instrumentOwner
        var unit = old.instrumentUnit
        var au = old.auAudioUnit
        var block = old.renderBlock

        if slot < 0 {
            track.pendingInstrumentRequestID = 0
            owner = nil
            unit = nil
            au = nil
            block = nil
        } else if slot < effects.count {
            effects[slot] = nil
        } else {
            return
        }
        track.processing = ProcessingResources(
            instrumentOwner: owner, instrumentUnit: unit,
            auAudioUnit: au, renderBlock: block,
            effects: effects,
            scratch: TrackScratchBuffers(frameCapacity: bufferSize)
        )
        publishRenderSnapshot()
    }

    func getInstrumentUnit(for trackID: TrackID) -> AudioUnit? {
        return tracks[trackID]?.processing.instrumentUnit
    }
    
    // MARK: - MIDI Processing
    
    private var renderErrorCount = 0
    
    func sendMIDI(to trackID: TrackID, status: UInt8, data1: UInt8, data2: UInt8, sampleOffset: UInt32) {
        withRenderSnapshot { snapshot in
            sendMIDI(to: trackID, status: status, data1: data1,
                     data2: data2, sampleOffset: sampleOffset, in: snapshot)
        }
    }

    private func sendMIDI(
        to trackID: TrackID, status: UInt8, data1: UInt8,
        data2: UInt8, sampleOffset: UInt32, in snapshot: RenderSnapshot
    ) {
        guard let processing = snapshot.byID[trackID]?.processing else { return }
        if let au = processing.auAudioUnit,
           let schedule = au.scheduleMIDIEventBlock {
            var midi: (UInt8, UInt8, UInt8) = (status, data1, data2)
            withUnsafeBytes(of: &midi) { bytes in
                if let address = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    schedule(AUEventSampleTimeImmediate, 0, 3, address)
                }
            }
        } else if let unit = processing.instrumentUnit {
            _ = MusicDeviceMIDIEvent(unit, UInt32(status),
                                     UInt32(data1), UInt32(data2), sampleOffset)
        }
    }

    func allNotesOff() {
        for track in tracks.values {
            guard let unit = track.processing.instrumentUnit else { continue }
            
            // Send all notes off on all channels
            for channel: UInt8 in 0..<16 {
                // All notes off (CC 123)
                MusicDeviceMIDIEvent(unit, UInt32(0xB0 | channel), 123, 0, 0)
                // All sound off (CC 120)
                MusicDeviceMIDIEvent(unit, UInt32(0xB0 | channel), 120, 0, 0)
            }
        }
    }
    
    // MARK: - Rendering
    
    // Pre-allocated stereo buffer list structure for rendering
    // AudioBufferList in Swift doesn't properly allocate space for multiple buffers,
    // so we use this struct to ensure proper memory layout
    private struct StereoBufferList {
        var mNumberBuffers: UInt32 = 2
        var mBuffers0: AudioBuffer = AudioBuffer()
        var mBuffers1: AudioBuffer = AudioBuffer()
    }
    
    /// Render all tracks and mix to output buffer
    /// Called from the audio thread - MUST be realtime safe
    /// Existing direct graph rendering remains available to hardware-free
    /// tests and exclusive offline paths. One callback/graph may render at a
    /// time, avoiding non-reentrant effects during live AU replacement.
    func render(
        frameCount: UInt32,
        currentSample: Int64,
        outputBuffer: UnsafeMutablePointer<AudioBufferList>
    ) {
        withRenderFrame { snapshot in
            renderRoutes(snapshot: snapshot, frameCount: frameCount,
                         currentSample: currentSample, outputBuffer: outputBuffer)
        }
    }

    /// Pin a single immutable generation for BOTH scheduled MIDI and AU audio
    /// within the current buffer. The live-published replacement becomes
    /// visible on the next buffer boundary, never halfway through a buffer.
    func renderWithScheduledMIDI(
        scheduler: MIDIScheduler,
        startSample: Int64,
        endSample: Int64,
        frameCount: UInt32,
        outputBuffer: UnsafeMutablePointer<AudioBufferList>
    ) {
        withRenderFrame { snapshot in
            _ = scheduler.processEvents(startSample: startSample, endSample: endSample) {
                event, offset in
                sendMIDI(to: event.trackID, status: event.status,
                         data1: event.data1, data2: event.data2,
                         sampleOffset: offset, in: snapshot)
            }
            renderRoutes(snapshot: snapshot, frameCount: frameCount,
                         currentSample: startSample, outputBuffer: outputBuffer)
        }
    }

    private func renderRoutes(
        snapshot: RenderSnapshot,
        frameCount: UInt32,
        currentSample: Int64,
        outputBuffer: UnsafeMutablePointer<AudioBufferList>
    ) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(outputBuffer)
        guard ablPointer.count >= 2 else { return }
        
        let outputLeft = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let outputRight = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        guard let outL = outputLeft, let outR = outputRight else { return }
        
        for track in snapshot.routes {
            // Skip muted tracks (or non-soloed tracks when solo is active)
            if track.controls.isMuted { continue }
            if snapshot.hasSoloedTracks && !track.controls.isSolo { continue }
            
            // Need either renderBlock (AUv3) or instrumentUnit (legacy)
            let bufferL = track.processing.scratch.left
            let bufferR = track.processing.scratch.right
            guard frameCount <= UInt32(track.processing.scratch.frameCapacity) else { continue }
            guard track.processing.renderBlock != nil || track.processing.instrumentUnit != nil else { continue }
            
            // Clear track buffer
            memset(bufferL, 0, Int(frameCount) * MemoryLayout<Float>.size)
            memset(bufferR, 0, Int(frameCount) * MemoryLayout<Float>.size)
            
            // Set up stereo buffer list with proper memory layout
            var stereoList = StereoBufferList()
            stereoList.mBuffers0 = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: frameCount * 4,
                mData: bufferL
            )
            stereoList.mBuffers1 = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: frameCount * 4,
                mData: bufferR
            )
            
            // Render instrument
            var timeStamp = AudioTimeStamp()
            timeStamp.mSampleTime = Float64(currentSample)
            timeStamp.mFlags = .sampleTimeValid
            
            var actionFlags = AudioUnitRenderActionFlags()
            var renderStatus: OSStatus = noErr
            
            // Use AUv3 renderBlock if available, otherwise fall back to AudioUnitRender
            if let renderBlock = track.processing.renderBlock {
                // AUv3 rendering using the render block
                renderStatus = withUnsafeMutablePointer(to: &stereoList) { stereoPtr in
                    stereoPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
                        renderBlock(&actionFlags, &timeStamp, frameCount, 0, ablPtr, nil)
                    }
                }
            } else if let instrument = track.processing.instrumentUnit {
                // Legacy AudioUnit rendering
                renderStatus = withUnsafeMutablePointer(to: &stereoList) { stereoPtr in
                    stereoPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
                        AudioUnitRender(instrument, &actionFlags, &timeStamp, 0, frameCount, ablPtr)
                    }
                }
            }
            
            // Never perform string interpolation or console I/O on the
            // real-time render callback. Failed renders are skipped, and audio
            // diagnostics can be collected asynchronously outside this path.
            if renderStatus != noErr {
                renderErrorCount += 1
                continue
            }
            
            // Process through effects
            for case let effect? in track.processing.effects {
                var effectTimeStamp = timeStamp
                var effectFlags = AudioUnitRenderActionFlags()
                withUnsafeMutablePointer(to: &stereoList) { stereoPtr in
                    stereoPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
                        AudioUnitRender(effect.unit, &effectFlags, &effectTimeStamp, 0, frameCount, ablPtr)
                    }
                }
            }
            
            // Apply volume and pan, mix to output
            let leftGain = track.controls.volume * (1.0 - max(0, track.controls.pan))
            let rightGain = track.controls.volume * (1.0 + min(0, track.controls.pan))
            
            for i in 0..<Int(frameCount) {
                outL[i] += bufferL[i] * leftGain
                outR[i] += bufferR[i] * rightGain
            }
         }
    }
}