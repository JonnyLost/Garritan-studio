import Foundation

/// How the Auto Sampler captures expression without introducing a second
/// sample-mapping format or modifying the native real-time sampler.
public enum StudioAutoSamplerExpression {
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case velocity
        case cc1Layers

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .velocity: return "Velocity layers"
            case .cc1Layers: return "CC1 dynamics"
            }
        }
    }

    /// In CC1 mode the mapping's velocity labels act as CC1 layer centers.
    /// The source AU receives a fixed note-on velocity so its own velocity
    /// response is not confused with its mod-wheel timbre.
    ///
    /// Sending CC11 is optional for existing velocity captures (nil keeps
    /// the source AU's own setting). CC1 mode uses an explicit reference CC11
    /// such as 127; the captured level is baked into the PCM, and the native
    /// sampler's live CC11 remains a further relative expression control.
    public struct Configuration: Sendable, Equatable {
        public var mode: Mode
        public var fixedNoteVelocity: UInt8
        public var sourceCC11: UInt8?

        public init(mode: Mode = .velocity,
                    fixedNoteVelocity: UInt8 = 100,
                    sourceCC11: UInt8? = nil) {
            self.mode = mode
            self.fixedNoteVelocity = fixedNoteVelocity
            self.sourceCC11 = sourceCC11
        }

        public var isValid: Bool {
            (1...127).contains(fixedNoteVelocity) &&
            (sourceCC11 == nil || (1...127).contains(sourceCC11!))
        }

        /// Studio's current native dynamic layer crossfader supports at most
        /// 8 discrete velocity bands for a single root/microphone group.
        public func canCaptureLayers(_ layers: [UInt8],
                                     captureReleaseTails: Bool) -> Bool {
            isValid && !layers.isEmpty && layers.count <= 8 &&
            Set(layers).count == layers.count &&
            layers.allSatisfy { (1...127).contains($0) } &&
            (mode != .cc1Layers || (layers.count >= 2 &&
                                   !captureReleaseTails))
        }

        /// The native sampler's CC1 crossfader uses the midpoint of each
        /// factory-assigned velocity *band*, not the original MIDI velocity
        /// label. Capture at those actual band centers so playback at CC1=90
        /// interpolates the timbres the performer heard at capture time.
        public static func cc1Centers(for layers: [UInt8]) -> [UInt8] {
            let sorted = Array(Set(layers)).sorted()
            return sorted.indices.map { index in
                let low = index == 0 ? 1 :
                    (Int(sorted[index - 1]) + Int(sorted[index])) / 2 + 1
                let high = index + 1 == sorted.count ? 127 :
                    (Int(sorted[index]) + Int(sorted[index + 1])) / 2
                return UInt8((low + high + 1) / 2)
            }
        }

        public func point(for mappedVelocity: UInt8,
                          allLayers: [UInt8]) -> Point {
            switch mode {
            case .velocity:
                return Point(mappedVelocity: mappedVelocity,
                             playedVelocity: mappedVelocity,
                             sourceCC1: nil, sourceCC11: sourceCC11)
            case .cc1Layers:
                let sorted = Array(Set(allLayers)).sorted()
                let centers = Self.cc1Centers(for: sorted)
                let layerIndex = sorted.firstIndex(of: mappedVelocity)
                return Point(mappedVelocity: mappedVelocity,
                             playedVelocity: fixedNoteVelocity,
                             sourceCC1: layerIndex.map { centers[$0] },
                             sourceCC11: sourceCC11 ?? 127)
            }
        }

        /// Use the existing StudioSamplerPatch version 1 and native CC1
        /// layer crossfader, which interpolates at playback without resampling
        /// or reloading the real-time graph.
        public func applying(to patch: StudioSamplerPatch) -> StudioSamplerPatch {
            guard mode == .cc1Layers else { return patch }
            var result = patch
            result.cc1Crossfade = true
            result.dynamicsCC1 = 96
            result.expressionCC11 = 127
            return result
        }
    }

    public struct Point: Equatable, Sendable {
        /// The value stored in the native sampler's layer key.
        public let mappedVelocity: UInt8
        /// The velocity actually sent to the source Audio Unit.
        public let playedVelocity: UInt8
        public let sourceCC1: UInt8?
        public let sourceCC11: UInt8?
    }
}
