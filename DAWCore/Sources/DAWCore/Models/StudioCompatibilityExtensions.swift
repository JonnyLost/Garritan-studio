import Foundation

// These compatibility helpers predate the optional StudioAI module.
// Keep them in DAWCore so the public project lookup API remains available
// to project/transport code regardless of AI/network feature availability.

// MARK: - Convenience Extensions

extension Project {
    /// Get a track by name (case-insensitive)
    public func trackByName(_ name: String) -> Track? {
        tracks.first { $0.name.lowercased() == name.lowercased() }
    }
    
    /// Get track index by name
    public func trackIndexByName(_ name: String) -> Int? {
        tracks.firstIndex { $0.name.lowercased() == name.lowercased() }
    }
}

// MARK: - Data Hex Extension

extension Data {
    public init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else { return nil }
        
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}
