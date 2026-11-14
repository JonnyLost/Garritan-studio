import Foundation
import AudioToolbox

/// Non-owning, render-thread-only view of the upstream stereo signal.
/// Owned by EffectLifetime, not by the AudioUnit that stores its refCon.
/// Sources always point at separately allocated, prefilled effect-input
/// scratch buffers, so output processing cannot overwrite its own input.
final class StudioEffectInputContext {
    private var left: UnsafePointer<Float>?
    private var right: UnsafePointer<Float>?
    private var firstSampleTime: Float64 = 0
    private var availableFrames: UInt32 = 0

    /// Only call from the sole admitted audio render frame.
    func setSource(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                   sampleTime: Float64, frames: UInt32) {
        self.left = left
        self.right = right
        firstSampleTime = sampleTime
        availableFrames = frames
    }

    /// Called synchronously by AudioUnitRender through the registered
    /// kAudioUnitProperty_SetRenderCallback on input bus zero.
    func supply(
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let output else { return kAudio_ParamError }
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard buffers.count == 2 else { return kAudio_ParamError }

        let byteCount = Int(frames) * MemoryLayout<Float>.size
        guard byteCount <= Int(UInt32.max) else { return kAudio_ParamError }

        var offset: UInt32 = 0
        if timeStamp.pointee.mFlags.contains(.sampleTimeValid) {
            let difference = timeStamp.pointee.mSampleTime - firstSampleTime
            if difference >= 0, difference < Double(UInt32.max) {
                offset = UInt32(difference)
            } else {
                return kAudio_ParamError
            }
        }

        guard let left, let right, offset <= availableFrames,
              frames <= availableFrames - offset else {
            // Unprepared input is silence. Never write past a caller-owned
            // buffer: return an error if the AU provided no valid capacity.
            guard let outL = buffers[0].mData, let outR = buffers[1].mData,
                  buffers[0].mDataByteSize >= UInt32(byteCount),
                  buffers[1].mDataByteSize >= UInt32(byteCount) else {
                return kAudio_ParamError
            }
            memset(outL, 0, byteCount)
            memset(outR, 0, byteCount)
            return noErr
        }

        // Audio Units may ask their upstream callback for borrowed input
        // pointers (mData = nil), or supply writable storage. Support BOTH
        // conventions. The borrowed pointers remain valid through the
        // synchronous AudioUnitRender call, not beyond this callback.
        for channel in 0..<2 {
            let source = channel == 0
                ? left.advanced(by: Int(offset))
                : right.advanced(by: Int(offset))
            if let destination = buffers[channel].mData,
               buffers[channel].mDataByteSize >= UInt32(byteCount) {
                memmove(destination, source, byteCount)
            } else {
                buffers[channel].mData = UnsafeMutableRawPointer(
                    mutating: UnsafeRawPointer(source)
                )
            }
            buffers[channel].mDataByteSize = UInt32(byteCount)
            buffers[channel].mNumberChannels = 1
        }
        return noErr
    }
}

/// C-compatible callback; never retains Swift objects, logs, allocates or
/// acquires a lock. EffectLifetime guarantees the context remains alive.
func studioEffectInputRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<StudioEffectInputContext>
        .fromOpaque(inRefCon).takeUnretainedValue()
    return context.supply(timeStamp: inTimeStamp, frames: inNumberFrames,
                          output: ioData)
}
