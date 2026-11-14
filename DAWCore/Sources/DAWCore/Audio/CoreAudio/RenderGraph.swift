import Foundation
import AudioToolbox
import AVFoundation

// MARK: - Render Graph

/// Manages the audio processing graph for all tracks
/// Handles plugin hosting, track mixing, and audio rendering
public final class RenderGraph {
    
    // MARK: - Track Node
    
    struct TrackNode {
        let id: TrackID
        var instrumentUnit: AudioUnit?
        var auAudioUnit: AUAudioUnit?  // For AUv3 rendering
        var renderBlock: AURenderBlock?  // AUv3 render callback
        var effectUnits: [AudioUnit?] = []
        var volume: Float = 1.0
        var pan: Float = 0.0
        var isMuted: Bool = false
        var isSolo: Bool = false
        
        // Pre-allocated render buffers
        var renderBufferLeft: UnsafeMutablePointer<Float>?
        var renderBufferRight: UnsafeMutablePointer<Float>?
    }
    
    // MARK: - Properties
    
    private var tracks: [TrackID: TrackNode] = [:]
    private var masterVolume: Float = 1.0
    private let sampleRate: Double
    private var bufferSize: Int
    
    // Track which tracks have solo enabled
    private var hasSoloedTracks: Bool = false
    
    // MARK: - Initialization
    
    init(sampleRate: Double, bufferSize: Int) {
        self.sampleRate = sampleRate
        self.bufferSize = bufferSize
    }
    
    deinit {
        // Clean up allocated buffers
        for track in tracks.values {
            track.renderBufferLeft?.deallocate()
            track.renderBufferRight?.deallocate()
        }
    }
    
    // MARK: - Configuration
    
    func setBufferSize(_ size: Int) {
        bufferSize = size
        
        // Reallocate buffers for all tracks
        for (id, track) in tracks {
            track.renderBufferLeft?.deallocate()
            track.renderBufferRight?.deallocate()
            
            var updatedTrack = track
            updatedTrack.renderBufferLeft = UnsafeMutablePointer<Float>.allocate(capacity: size)
            updatedTrack.renderBufferRight = UnsafeMutablePointer<Float>.allocate(capacity: size)
            updatedTrack.renderBufferLeft?.initialize(repeating: 0, count: size)
            updatedTrack.renderBufferRight?.initialize(repeating: 0, count: size)
            tracks[id] = updatedTrack
        }
    }
    
    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
    }
    
    // MARK: - Track Management
    
    func createTrack(id: TrackID) {
        guard tracks[id] == nil else { return }
        
        var track = TrackNode(id: id)
        
        // Allocate render buffers
        track.renderBufferLeft = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
        track.renderBufferRight = UnsafeMutablePointer<Float>.allocate(capacity: bufferSize)
        track.renderBufferLeft?.initialize(repeating: 0, count: bufferSize)
        track.renderBufferRight?.initialize(repeating: 0, count: bufferSize)
        
        tracks[id] = track
        print("[RenderGraph] Created track \(id.rawValue)")
    }
    
    func removeTrack(id: TrackID) {
        guard let track = tracks[id] else { return }
        
        // Release AVAudioUnit (which owns the AudioUnit)
        // Don't call AudioComponentInstanceDispose - AVAudioUnit handles cleanup
        avAudioUnits.removeValue(forKey: id)
        
        // Dispose of effect units
        for case let unit? in track.effectUnits {
            AudioComponentInstanceDispose(unit)
        }
        
        // Free buffers
        track.renderBufferLeft?.deallocate()
        track.renderBufferRight?.deallocate()
        
        tracks.removeValue(forKey: id)
        updateSoloState()
        
        print("[RenderGraph] Removed track \(id.rawValue)")
    }
    
    func setTrackVolume(_ volume: Float, for trackID: TrackID) {
        tracks[trackID]?.volume = volume
    }
    
    func setTrackPan(_ pan: Float, for trackID: TrackID) {
        tracks[trackID]?.pan = pan
    }
    
    func setTrackMute(_ muted: Bool, for trackID: TrackID) {
        tracks[trackID]?.isMuted = muted
    }
    
    func setTrackSolo(_ solo: Bool, for trackID: TrackID) {
        tracks[trackID]?.isSolo = solo
        updateSoloState()
    }
    
    private func updateSoloState() {
        hasSoloedTracks = tracks.values.contains { $0.isSolo }
    }
    
    // Store AVAudioUnits to keep them alive (AUv3 requires this)
    private var avAudioUnits: [TrackID: AVAudioUnit] = [:]
    
    // MARK: - Plugin Loading
    
    func loadInstrument(
        _ description: AudioComponentDescription,
        for trackID: TrackID
    ) async throws -> AudioUnit {
        guard var track = tracks[trackID] else {
            throw AudioBackendError.trackNotFound(trackID)
        }
        
        // Keep the previous AVAudioUnit alive until replacement succeeds.
        // AVAudioUnit owns its AudioUnit; never dispose that handle ourselves.
        
        // Use AVAudioUnit to properly instantiate AUv3 plugins
        // This ensures proper initialization that raw AudioComponentInstanceNew might miss
        let avAudioUnit = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAudioUnit, Error>) in
            AVAudioUnit.instantiate(with: description, options: []) { avUnit, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let avUnit = avUnit {
                    continuation.resume(returning: avUnit)
                } else {
                    continuation.resume(throwing: AudioBackendError.pluginLoadFailed("Unknown error"))
                }
            }
        }
        
        // Keep the old unit alive until the new one has allocated
        // resources and is ready to replace it.
        // Get the underlying AudioUnit
        let unit = avAudioUnit.audioUnit
        
        // Set up the audio unit with our format
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
        
        let formatStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        
        if formatStatus != noErr {
            print("[RenderGraph] Warning: Could not set stream format: \(formatStatus)")
        }
        
        // Set maximum frames per slice (important for proper rendering)
        var maxFrames: UInt32 = UInt32(bufferSize)
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )
        
        // Allocate render resources
        let auAudioUnit = avAudioUnit.auAudioUnit
        try auAudioUnit.allocateRenderResources()
        
        // Get the render block for AUv3 rendering
        let renderBlock = auAudioUnit.renderBlock
        
        track.instrumentUnit = unit
        track.auAudioUnit = auAudioUnit
        track.renderBlock = renderBlock
        avAudioUnits[trackID] = avAudioUnit
        tracks[trackID] = track
        
        print("[RenderGraph] Loaded instrument for track \(trackID.rawValue) using AVAudioUnit (renderBlock: \(renderBlock != nil ? "✓" : "nil"))")
        return unit
    }
    
    func loadEffect(
        _ description: AudioComponentDescription,
        for trackID: TrackID,
        slot: Int
    ) async throws -> AudioUnit {
        guard var track = tracks[trackID] else {
            throw AudioBackendError.trackNotFound(trackID)
        }
        guard slot >= 0 && slot < 64 else {
            throw AudioBackendError.configurationError("Effect slot must be between 0 and 63")
        }

        // Find and instantiate component
        var desc = description
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioBackendError.pluginLoadFailed("Effect component not found")
        }
        
        var audioUnit: AudioComponentInstance?
        let status = AudioComponentInstanceNew(component, &audioUnit)
        
        guard status == noErr, let unit = audioUnit else {
            throw AudioBackendError.pluginLoadFailed("Failed to instantiate effect: \(status)")
        }
        
        // Configure effect
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
        
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        
        let initializeStatus = AudioUnitInitialize(unit)
        guard initializeStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioBackendError.pluginLoadFailed("Effect initialization failed: \(initializeStatus)")
        }
        
        // Sparse effect slots must not alias the same AudioUnit instance.
        // Replace only the selected slot; dispose its previous owner once.
        while track.effectUnits.count <= slot {
            track.effectUnits.append(nil)
        }
        if let previous = track.effectUnits[slot] {
            AudioComponentInstanceDispose(previous)
        }
        track.effectUnits[slot] = unit
        tracks[trackID] = track
        
        print("[RenderGraph] Loaded effect at slot \(slot) for track \(trackID.rawValue)")
        return unit
    }
    
    func unloadPlugin(for trackID: TrackID, slot: Int) {
        guard var track = tracks[trackID] else { return }
        
        if slot < 0 {
            // Unload instrument - release AVAudioUnit (don't dispose directly)
            avAudioUnits.removeValue(forKey: trackID)
            track.instrumentUnit = nil
            track.auAudioUnit = nil
            track.renderBlock = nil
        } else if slot < track.effectUnits.count {
            if let unit = track.effectUnits[slot] {
                AudioComponentInstanceDispose(unit)
            }
            track.effectUnits[slot] = nil
        }
        
        tracks[trackID] = track
    }
    
    func getInstrumentUnit(for trackID: TrackID) -> AudioUnit? {
        return tracks[trackID]?.instrumentUnit
    }
    
    // MARK: - MIDI Processing
    
    private var renderErrorCount = 0
    
    func sendMIDI(to trackID: TrackID, status: UInt8, data1: UInt8, data2: UInt8, sampleOffset: UInt32) {
        guard let track = tracks[trackID] else { return }

        // Called by the real-time scheduler: never log or format strings here.
        if let auAudioUnit = track.auAudioUnit,
           let scheduleMIDIEventBlock = auAudioUnit.scheduleMIDIEventBlock {
            let midiData: [UInt8] = [status, data1, data2]
            midiData.withUnsafeBufferPointer { buffer in
                scheduleMIDIEventBlock(AUEventSampleTimeImmediate, 0, 3, buffer.baseAddress!)
            }
        } else if let unit = track.instrumentUnit {
            _ = MusicDeviceMIDIEvent(
                unit, UInt32(status), UInt32(data1), UInt32(data2), sampleOffset
            )
        }
    }

        func allNotesOff() {
        for track in tracks.values {
            guard let unit = track.instrumentUnit else { continue }
            
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
    func render(
        frameCount: UInt32,
        currentSample: Int64,
        outputBuffer: UnsafeMutablePointer<AudioBufferList>
    ) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(outputBuffer)
        guard ablPointer.count >= 2 else { return }
        
        let outputLeft = ablPointer[0].mData?.assumingMemoryBound(to: Float.self)
        let outputRight = ablPointer[1].mData?.assumingMemoryBound(to: Float.self)
        
        guard let outL = outputLeft, let outR = outputRight else { return }
        
        for (_, track) in tracks {
            // Skip muted tracks (or non-soloed tracks when solo is active)
            if track.isMuted { continue }
            if hasSoloedTracks && !track.isSolo { continue }
            
            // Need either renderBlock (AUv3) or instrumentUnit (legacy)
            guard let bufferL = track.renderBufferLeft,
                  let bufferR = track.renderBufferRight else { continue }
            guard track.renderBlock != nil || track.instrumentUnit != nil else { continue }
            
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
            if let renderBlock = track.renderBlock {
                // AUv3 rendering using the render block
                renderStatus = withUnsafeMutablePointer(to: &stereoList) { stereoPtr in
                    stereoPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
                        renderBlock(&actionFlags, &timeStamp, frameCount, 0, ablPtr, nil)
                    }
                }
            } else if let instrument = track.instrumentUnit {
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
            for case let effect? in track.effectUnits {
                var effectTimeStamp = timeStamp
                var effectFlags = AudioUnitRenderActionFlags()
                withUnsafeMutablePointer(to: &stereoList) { stereoPtr in
                    stereoPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
                        AudioUnitRender(effect, &effectFlags, &effectTimeStamp, 0, frameCount, ablPtr)
                    }
                }
            }
            
            // Apply volume and pan, mix to output
            let leftGain = track.volume * (1.0 - max(0, track.pan))
            let rightGain = track.volume * (1.0 + min(0, track.pan))
            
            for i in 0..<Int(frameCount) {
                outL[i] += bufferL[i] * leftGain
                outR[i] += bufferR[i] * rightGain
            }
        }
    }
}
