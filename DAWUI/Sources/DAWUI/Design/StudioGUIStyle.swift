import SwiftUI

/// Shared visual primitives for the Garritan Studio GUI refresh.
///
/// These deliberately supplement existing appearance tokens until each workspace
/// has been audited. No playback, mixer routing, or project state is modified.
public enum StudioGUI {
    public static let background = Color(red: 16 / 255, green: 19 / 255, blue: 25 / 255)
    public static let panel = Color(red: 30 / 255, green: 37 / 255, blue: 48 / 255)
    public static let raised = Color(red: 48 / 255, green: 60 / 255, blue: 77 / 255)
    public static let selection = Color(red: 131 / 255, green: 178 / 255, blue: 219 / 255)
    public static let activity = Color(red: 87 / 255, green: 183 / 255, blue: 161 / 255)
    public static let accent = Color(red: 216 / 255, green: 169 / 255, blue: 107 / 255)
    public static let secondaryText = Color(red: 158 / 255, green: 172 / 255, blue: 191 / 255)
}

/// Compact parameter control intended for pan, sends, wet/dry and ambience.
/// Uses a native Binding so automation and value changes remain with the caller.
/// Existing horizontal faders should remain for channel volume.
public struct StudioParameterKnob: View {
    public let title: String
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let formattedValue: (Double) -> String
    public let tint: Color

    @State private var dragStartValue: Double?

    public init(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        tint: Color = StudioGUI.selection,
        formattedValue: @escaping (Double) -> String = { String(format: "%.0f", $0) }
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.tint = tint
        self.formattedValue = formattedValue
    }

    private var normalizedValue: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(StudioGUI.background)
                    .overlay(Circle().stroke(StudioGUI.raised, lineWidth: 2))
                Circle()
                    .trim(from: 0, to: normalizedValue * 0.75)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(4)
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 2, height: 16)
                    .offset(y: -13)
                    .rotationEffect(.degrees(-135 + normalizedValue * 270))
            }
            .frame(width: 58, height: 58)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        if dragStartValue == nil { dragStartValue = value }
                        let delta = Double(-gesture.translation.height) / 150
                        let span = range.upperBound - range.lowerBound
                        value = min(range.upperBound, max(range.lowerBound, (dragStartValue ?? value) + delta * span))
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(formattedValue(value))
            .accessibilityAdjustableAction { direction in
                let step = (range.upperBound - range.lowerBound) / 100
                switch direction {
                case .increment: value = min(range.upperBound, value + step)
                case .decrement: value = max(range.lowerBound, value - step)
                @unknown default: break
                }
            }

            Text(formattedValue(value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(StudioGUI.secondaryText)
        }
        .frame(minWidth: 76)
        .help("\(title): \(formattedValue(value))")
    }
}
