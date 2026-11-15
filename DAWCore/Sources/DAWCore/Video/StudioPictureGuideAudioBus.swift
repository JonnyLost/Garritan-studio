import AVFoundation
import Foundation

/// A dedicated reference-audio channel in Studio's existing AVAudioEngine.
///
/// The graph is attached during ProjectViewModel initialization, BEFORE the
/// engine starts, to avoid disrupting orchestral playback on movie import.
/// The source never passes through an orchestral stage reverb or track FX.
@MainActor
public final class StudioPictureGuideAudioBus {
    private let engine: AudioEngine
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private var file: AVAudioFile?
    private var scheduled = false
    private var enabled = false
    private var volume: Float = 0.65
    private var suppressForExport = false
    private var scheduledStartFrame: AVAudioFramePosition?

    public var hasAudio: Bool { file != nil }
    public var isAudible: Bool { enabled && !suppressForExport && file != nil }

    public init(audioEngine: AudioEngine) {
        engine = audioEngine
        let format = AVAudioFormat(
            standardFormatWithSampleRate: audioEngine.sampleRate, channels: 2)!
        audioEngine.engine.attach(player)
        audioEngine.engine.attach(mixer)
        audioEngine.engine.connect(player, to: mixer, format: format)
        audioEngine.engine.connect(mixer, to: audioEngine.engine.mainMixerNode,
                                   format: format)
        mixer.outputVolume = 0
    }

    /// Load a file-backed compressed M4A guide without allocating its PCM
    /// duration in RAM. AVAudioPlayerNode handles sample-rate conversion.
    public func load(fileURL: URL) throws {
        player.stop()
        scheduled = false
        scheduledStartFrame = nil
        file = try AVAudioFile(forReading: fileURL)
        refreshGain()
    }

    public func clear() {
        player.stop()
        scheduled = false
        scheduledStartFrame = nil
        file = nil
        enabled = false
        refreshGain()
    }

    public func setMix(enabled: Bool, volume: Float) {
        self.enabled = enabled
        self.volume = volume.isFinite ? max(0, min(1, volume)) : 0.65
        refreshGain()
        if !isAudible {
            player.stop()
            scheduled = false
            scheduledStartFrame = nil
        }
    }

    /// Studio's score and stem exports must never include production dialogue.
    /// A pre-existing guide session is paused and will be rescheduled after
    /// the export is complete on the next transport play.
    public func setExportSuppressed(_ suppressed: Bool) {
        suppressForExport = suppressed
        refreshGain()
        if suppressed {
            player.stop()
            scheduled = false
            scheduledStartFrame = nil
        }
    }

    private func refreshGain() {
        mixer.outputVolume = isAudible ? volume : 0
    }

    public func synchronize(projectSeconds: Double,
                            pictureStartSeconds: Double,
                            playing: Bool,
                            discontinuity: Bool) {
        guard let file, isAudible,
              projectSeconds.isFinite, pictureStartSeconds.isFinite,
              playing else {
            if scheduled {
                player.stop()
                scheduled = false
                scheduledStartFrame = nil
            }
            return
        }

        let offset = projectSeconds - pictureStartSeconds
        guard offset >= 0, offset < Double(file.length) / file.processingFormat.sampleRate
        else {
            if scheduled {
                player.stop()
                scheduled = false
                scheduledStartFrame = nil
            }
            return
        }

        // The source's actual decoded sample rate determines its frame number;
        // the mixer handles conversion to the current Mac output sample rate.
        let frame = AVAudioFramePosition((offset * file.processingFormat.sampleRate).rounded(.down))
        guard frame >= 0, frame < file.length else { return }
        if scheduled && !discontinuity && player.isPlaying { return }

        player.stop()
        let remaining = file.length - frame
        let frameCount = AVAudioFrameCount(min(remaining, Int64(UInt32.max)))
        guard frameCount > 0 else {
            scheduled = false
            scheduledStartFrame = nil
            return
        }
        player.scheduleSegment(file, startingFrame: frame,
                               frameCount: frameCount, at: nil)
        player.play()
        scheduled = true
        scheduledStartFrame = frame
    }

    public func stop() {
        player.stop()
        scheduled = false
        scheduledStartFrame = nil
    }
}
