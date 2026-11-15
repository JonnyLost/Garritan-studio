import AudioToolbox

/// Core Audio render-path adapter. `sampleTime` is an absolute AU render
/// sample time, NOT a buffer offset or a host-time timestamp. Call immediately
/// before rendering that AU in the same sample coordinate. This adapter is
/// deliberately separate from live/ARIA compatibility delivery.
enum StudioAUMIDIScheduling {
    static func send(status: UInt8, data1: UInt8, data2: UInt8,
                     sampleTime: Int64, using schedule: AUScheduleMIDIEventBlock) {
        var packet = (status, data1, data2)
        withUnsafeBytes(of: &packet) { bytes in
            schedule(sampleTime, 0, StudioMIDIClockMath.packetLength(status: status),
                     bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
    }
}
