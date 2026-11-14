import SwiftUI
import DAWCore

/// One visual and gesture implementation for orchestral controller lanes.
/// The parent owns a temporary MIDI draft and commits exactly once on mouse-up.
struct StudioExpressionLaneCanvas: View {
    let events: [MIDIEvent] // all positions are absolute project beats
    let lane: CCType
    let mode: StudioExpressionDrawMode
    let channel: UInt8
    let pixelsPerBeat: Double
    let width: CGFloat
    let height: CGFloat
    let beatsPerBar: Double
    let playheadBeat: Double
    let onDraw: (StudioMIDIExpressionPoint) -> Void
    let onFinish: () -> Void

    var body: some View {
        Canvas { context, size in
            let gridBeats = min(4096, Int(ceil(Double(size.width) / pixelsPerBeat)) + 1)
            for beat in 0...gridBeats {
                let x = CGFloat(beat) * pixelsPerBeat
                let line = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(line, with: .color(.gray.opacity(0.17)), lineWidth: 0.5)
            }
            if beatsPerBar > 0 {
                let bars = min(2048, Int(ceil(Double(gridBeats) / beatsPerBar)))
                for bar in 0...bars {
                    let x = Double(bar) * beatsPerBar * pixelsPerBeat
                    let line = Path { p in
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(line, with: .color(.gray.opacity(0.45)), lineWidth: 1)
                }
            }
            if lane == .pitchBend {
                let center = Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                context.stroke(center, with: .color(.gray.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            let points: [(Double, Double)] = events.compactMap { event in
                guard let normalized = StudioMIDIExpressionEditing.normalizedValue(
                    of: event, for: lane, channel: channel
                ) else { return nil }
                return (event.beatPosition, normalized)
            }.sorted { $0.0 < $1.0 }

            var curve = Path()
            for (i, point) in points.enumerated() {
                let x = point.0 * pixelsPerBeat
                let y = (1 - point.1) * Double(size.height)
                let position = CGPoint(x: x, y: y)
                if i == 0 {
                    curve.move(to: position)
                } else {
                    curve.addLine(to: position)
                }
                let dot = CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(Color.orange))
            }
            context.stroke(curve, with: .color(Color.orange), lineWidth: 1.75)

            let x = playheadBeat * pixelsPerBeat
            let playhead = Path { p in
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(playhead, with: .color(.accentColor), lineWidth: 1)
        }
        .frame(width: width, height: height)
        .background(Color.black.opacity(0.15))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let beat = max(0, Double(gesture.location.x) / pixelsPerBeat)
                    let level = max(0, min(1, 1 - Double(gesture.location.y) /
                                         max(1, Double(height))))
                    onDraw(StudioMIDIExpressionPoint(beat: beat, value: level))
                }
                .onEnded { _ in onFinish() }
        )
        .accessibilityLabel("MIDI \(lane.name) \(mode.rawValue) expression lane")
        .help(mode.help)
    }
}
