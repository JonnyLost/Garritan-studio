import Foundation

/// Explicit source-AU keyswitch assignments. We never guess a plugin's
/// undocumented articulation layout from its name or bank.
public enum StudioAutoSamplerArticulations {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var name: String
        public var sourceKeyswitch: UInt8
        public var id: String { "\(name):\(sourceKeyswitch)" }

        public init(name: String, sourceKeyswitch: UInt8) {
            self.name = name
            self.sourceKeyswitch = sourceKeyswitch
        }
    }

    public struct Plan: Sendable, Equatable {
        /// Empty means the original single-sound capture.
        public var entries: [Entry]
        public var sourceChannel: UInt8
        /// Source keyswitch is a momentary note-on/off, then the playable
        /// note is rendered. This does not emit program changes.
        public init(entries: [Entry] = [], sourceChannel: UInt8 = 1) {
            self.entries = entries
            self.sourceChannel = sourceChannel
        }

        public var isValid: Bool {
            (1...16).contains(sourceChannel) && entries.count <= 15 &&
            (entries.isEmpty || entries.count >= 2) &&
            Set(entries.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == entries.count &&
            Set(entries.map(\.sourceKeyswitch)).count == entries.count &&
            (entries.isEmpty || entries[0].name.trimmingCharacters(
                in: .whitespacesAndNewlines).lowercased() == "sustain") &&
            entries.enumerated().allSatisfy { index, entry in
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return !name.isEmpty && name.count <= 48 &&
                    (index == 0 || !["sustain", "default"].contains(name.lowercased())) &&
                    entry.sourceKeyswitch <= 127
            }
        }

        public func isValid(for roots: [UInt8], velocities: [UInt8],
                            captureReleases: Bool) -> Bool {
            guard isValid, !roots.isEmpty, !velocities.isEmpty,
                  (entries.isEmpty || !captureReleases) else { return false }
            let count = roots.count * velocities.count * max(1, entries.count)
            return count > 0 && count <= (captureReleases ? 64 : 128) &&
                entries.allSatisfy { !roots.contains($0.sourceKeyswitch) }
        }

        public var effectiveEntries: [Entry] {
            entries.isEmpty ? [.init(name: "Sustain", sourceKeyswitch: 0)] : entries
        }

        /// The instrument factory assigns deterministic IDs and a separate
        /// native keyswitch map; original AU source switches are not copied
        /// into the playable range.
        public func applying(to patch: StudioSamplerPatch) -> StudioSamplerPatch {
            patch
        }
    }
}
