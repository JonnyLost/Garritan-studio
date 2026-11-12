import SwiftUI

/// Lightweight Studio Synth visualizer. Pure SwiftUI drawing, not a second
/// audio oscillator. It depicts the actual six harmonic frame recipes and
/// live custom partial values without polling audio samples or using Metal.
struct StudioWavetableWaveformPreview: View {
    let position: Double
    let harmonics: [Float]

    private func amplitude(frame: Int, harmonic: Int) -> Double {
        switch frame {
        case 0:
            return harmonic == 1 ? 1 : 0
        case 1:
            guard harmonic % 2 == 1 else { return 0 }
            return (harmonic / 2) % 2 == 0
                ? 1 / Double(harmonic * harmonic)
                : -1 / Double(harmonic * harmonic)
        case 2:
            return (harmonic % 2 == 1 ? 1 : -1) / Double(harmonic)
        case 3:
            return harmonic % 2 == 1 ? 1 / Double(harmonic) : 0
        case 4:
            switch harmonic {
            case 1: return 0.72
            case 2: return 0.23
            case 5: return 0.43
            case 7: return -0.28
            case 11: return 0.17
            case 15: return 0.12
            default: return 0
            }
        default:
            let index = harmonic - 1
            return harmonics.indices.contains(index)
                ? Double(harmonics[index]) : 0
        }
    }

    private func wave(frame: Int, phase: Double) -> Double {
        let value = (1...16).reduce(0.0) { sum, h in
            sum + amplitude(frame: frame, harmonic: h)
                * sin(2 * .pi * Double(h) * phase)
        }
        let normalization = max(1.0, (1...16).reduce(0.0) {
            $0 + abs(amplitude(frame: frame, harmonic: $1))
        })
        return value / normalization
    }

    private func morphedWave(position: Double, phase: Double) -> Double {
        let clamped = min(5, max(0, position))
        let lo = Int(clamped)
        let hi = min(5, lo + 1)
        let fraction = clamped - Double(lo)
        return wave(frame: lo, phase: phase) * (1 - fraction) +
               wave(frame: hi, phase: phase) * fraction
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let w = size.width, h = size.height
            guard w > 0 && h > 0 else { return }

            // Depth strokes represent nearby wavetable positions.
            for layer in 0..<15 {
                let z = Double(layer) / 14
                let frame = min(5, max(0, position + (z - 0.5) * 2.2))
                var path = Path()
                for i in 0...220 {
                    let t = Double(i) / 220
                    let sample = morphedWave(position: frame, phase: t)
                    let x = 18 + CGFloat(t) * (w - 60) + CGFloat(z) * 27
                    let y = h * (0.62 - CGFloat(z) * 0.28) -
                            CGFloat(sample) * h * 0.25
                    let point = CGPoint(x: x, y: y)
                    if i == 0 { path.move(to: point) }
                    else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(
                    Color.cyan.opacity(0.22 + 0.67 * z)),
                    lineWidth: z > 0.9 ? 2 : 1)
            }
        }
        .accessibilityLabel("3D-style wavetable morph view")
    }
}
