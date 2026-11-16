import SwiftUI
import DAWCore

/// First-generation native modular patchboard. Its cables drive the same C++
/// synthesis graph used by the Analog controls; there is no second audio path.
/// One jack can accept one cable, while one output may feed several jacks.
/// Click an output and then a compatible input to patch them together.
public struct StudioAnalogPatchboardView: View {
    @ObservedObject private var viewModel: ProjectViewModel
    public let trackID: TrackID

    @State private var pendingSource: StudioAnalogModule?
    @State private var selectedCableID: String?
    @State private var gainDraft: Double = 1
    @State private var warning: String?
    @State private var undoStack: [[StudioAnalogConnection]] = []
    @State private var redoStack: [[StudioAnalogConnection]] = []

    public init(viewModel: ProjectViewModel, trackID: TrackID) {
        self.viewModel = viewModel
        self.trackID = trackID
    }

    private var cables: [StudioAnalogConnection] {
        viewModel.project.track(withID: trackID)?.studioAnalogPatch?.activeConnections
            ?? StudioAnalogConnection.factory
    }

    private var selectedCable: StudioAnalogConnection? {
        cables.first(where: { $0.id == selectedCableID })
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("PATCHBOARD", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.bold))
                HStack(spacing: 5) {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                    Text("Audio").font(.caption2)
                    Circle().fill(.cyan).frame(width: 7, height: 7)
                    Text("Modulation").font(.caption2)
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    undoCable()
                } label: {
                    Label("Undo Cable", systemImage: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty)
                Button {
                    redoCable()
                } label: {
                    Label("Redo Cable", systemImage: "arrow.uturn.forward")
                }
                .disabled(redoStack.isEmpty)
                Button {
                    commit(StudioAnalogConnection.factory)
                } label: {
                    Label("Factory Cables", systemImage: "arrow.counterclockwise")
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text(pendingSource.map {
                    "Selected \($0.title) output. Click a matching destination jack to connect."
                } ?? "Click any module's OUT jack, then click a matching IN jack. Select a cable below to adjust its gain or disconnect it.")
                Spacer(minLength: 6)
                if pendingSource != nil {
                    Button("Cancel") { pendingSource = nil }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)

            if let warning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(warning)
                    Spacer(minLength: 8)
                    Button("Dismiss") { self.warning = nil }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            Divider().padding(.top, 10)

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.56))
                        .frame(width: BoardLayout.width, height: BoardLayout.height)

                    // Wire geometry and cards share one fixed logical canvas.
                    // ScrollView lets these patch jacks remain usable in the
                    // narrower docked Instruments workspace.
                    ForEach(cables) { cable in
                        CableCurve(cable: cable,
                                   selected: cable.id == selectedCableID)
                            .allowsHitTesting(false)
                    }

                    ForEach(StudioAnalogModule.allCases) { module in
                        PatchModuleCard(
                            module: module,
                            isSelectedSource: module == pendingSource,
                            onOutput: { selectOutput(module) },
                            onInput: { jack in connect(to: module, input: jack) }
                        )
                        .frame(width: BoardLayout.nodeWidth, height: BoardLayout.nodeHeight)
                        .position(
                            x: BoardLayout.origin(for: module).x + BoardLayout.nodeWidth / 2,
                            y: BoardLayout.origin(for: module).y + BoardLayout.nodeHeight / 2
                        )
                    }
                }
                .frame(width: BoardLayout.width, height: BoardLayout.height)
                .padding(12)
            }

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("CABLES")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                    Text("\(cables.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let selectedCable {
                        Button(role: .destructive) {
                            disconnect(selectedCable)
                        } label: {
                            Label("Disconnect Selected", systemImage: "cable.connector.slash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(cables) { cable in
                            Button {
                                selectedCableID = cable.id
                                gainDraft = Double(cable.gain)
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(cable.signal == .audio ? .orange : .cyan)
                                        .frame(width: 6, height: 6)
                                    Text("\(cable.source.title) → \(cable.destination.title) / \(jackName(cable))")
                                        .lineLimit(1)
                                }
                                .font(.caption2)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(cable.id == selectedCableID
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.055),
                                    in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let selectedCable {
                    HStack(spacing: 11) {
                        Text("Cable Gain")
                            .font(.caption.weight(.medium))
                        Slider(value: $gainDraft, in: -2...2, step: 0.05)
                            .frame(maxWidth: 210)
                        Text(String(format: "%.2f×", gainDraft))
                            .font(.caption.monospacedDigit())
                            .frame(width: 58)
                        Button("Apply Gain") {
                            var updated = selectedCable
                            updated.gain = Float(gainDraft)
                            commit(cables.map { $0.id == updated.id ? updated : $0 })
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            }
            .padding(12)
        }
    }

    private func jackName(_ cable: StudioAnalogConnection) -> String {
        cable.destination.inputs.first(where: { $0.index == cable.input })?.name ?? "IN"
    }

    private func selectOutput(_ module: StudioAnalogModule) {
        guard module.isOutputAvailable else { return }
        pendingSource = pendingSource == module ? nil : module
        warning = nil
    }

    private func connect(to destination: StudioAnalogModule, input: StudioAnalogInput) {
        guard let source = pendingSource else {
            warning = "Select a module's OUT jack first."
            return
        }
        guard source.signal == input.signal else {
            warning = "Incompatible cable: \(source.signal.rawValue) cannot connect to \(input.signal.rawValue)."
            return
        }
        // Replacement is one edit: the previous cable at that jack is removed
        // only if native validation accepts the completed new graph.
        let connection = StudioAnalogConnection(source: source, destination: destination,
                                                input: input.index)
        let proposed = cables.filter {
            !($0.destination == destination && $0.input == input.index)
        } + [connection]
        if commit(proposed) {
            pendingSource = nil
            selectedCableID = connection.id
            gainDraft = 1
        }
    }

    private func disconnect(_ cable: StudioAnalogConnection) {
        if commit(cables.filter { $0.id != cable.id }) {
            selectedCableID = nil
        }
    }

    /// All graph validation and ownership checks happen off the render thread.
    /// A pending-buffer swap is reported as busy and does not alter project
    /// storage. Native C++ compilation is authoritative for feedback cycles.
    @discardableResult
    private func commit(_ proposed: [StudioAnalogConnection]) -> Bool {
        let old = cables
        guard proposed != old else {
            warning = nil
            return true
        }
        do {
            try viewModel.setStudioAnalogConnections(proposed, for: trackID)
            undoStack.append(old)
            redoStack.removeAll()
            warning = nil
            return true
        } catch {
            warning = error.localizedDescription
            return false
        }
    }

    private func undoCable() {
        guard let previous = undoStack.last else { return }
        let current = cables
        do {
            try viewModel.setStudioAnalogConnections(previous, for: trackID)
            undoStack.removeLast()
            redoStack.append(current)
            selectedCableID = nil
            warning = nil
        } catch {
            warning = error.localizedDescription
        }
    }

    private func redoCable() {
        guard let next = redoStack.last else { return }
        let current = cables
        do {
            try viewModel.setStudioAnalogConnections(next, for: trackID)
            redoStack.removeLast()
            undoStack.append(current)
            selectedCableID = nil
            warning = nil
        } catch {
            warning = error.localizedDescription
        }
    }
}

private enum BoardLayout {
    static let nodeWidth: CGFloat = 194
    static let nodeHeight: CGFloat = 156
    static let width: CGFloat = 1340
    static let height: CGFloat = 600

    static func origin(for module: StudioAnalogModule) -> CGPoint {
        switch module {
        case .oscillator1: return CGPoint(x: 24, y: 24)
        case .oscillator2: return CGPoint(x: 24, y: 212)
        case .noise: return CGPoint(x: 24, y: 400)
        case .mixer: return CGPoint(x: 295, y: 212)
        case .filterEnvelope: return CGPoint(x: 295, y: 400)
        case .lfo: return CGPoint(x: 564, y: 400)
        case .filter: return CGPoint(x: 564, y: 212)
        case .amplitudeEnvelope: return CGPoint(x: 833, y: 400)
        case .vca: return CGPoint(x: 833, y: 212)
        case .output: return CGPoint(x: 1105, y: 212)
        }
    }

    static func output(for module: StudioAnalogModule) -> CGPoint {
        let point = origin(for: module)
        return CGPoint(x: point.x + nodeWidth + 7, y: point.y + 78)
    }

    static func input(for module: StudioAnalogModule, index: UInt8) -> CGPoint {
        let point = origin(for: module)
        return CGPoint(x: point.x - 7, y: point.y + 64 + CGFloat(index) * 25)
    }
}

private struct CableCurve: View {
    let cable: StudioAnalogConnection
    let selected: Bool

    var body: some View {
        let start = BoardLayout.output(for: cable.source)
        let end = BoardLayout.input(for: cable.destination, index: cable.input)
        let spread = max(60, abs(end.x - start.x) * 0.48)
        Path { path in
            path.move(to: start)
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x + spread, y: start.y),
                          control2: CGPoint(x: end.x - spread, y: end.y))
        }
        .stroke(cable.signal == .audio ? Color.orange : Color.cyan,
                style: StrokeStyle(lineWidth: selected ? 4 : 2.4, lineCap: .round))
        .opacity(selected ? 1 : 0.69)
        .shadow(color: cable.signal == .audio ? .orange.opacity(0.2) : .cyan.opacity(0.2),
                radius: selected ? 6 : 2)
    }
}

private struct PatchModuleCard: View {
    let module: StudioAnalogModule
    let isSelectedSource: Bool
    let onOutput: () -> Void
    let onInput: (StudioAnalogInput) -> Void

    private var accent: Color { module.signal == .audio ? .orange : .cyan }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: module.signal == .audio
                      ? "waveform" : "waveform.path.ecg")
                    .foregroundStyle(accent)
                Text(module.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 26)
            Text(module.subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 20, alignment: .leading)

            Rectangle().fill(accent.opacity(0.3)).frame(height: 1)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(module.inputs) { input in
                    Button {
                        onInput(input)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .strokeBorder(input.signal == .audio ? .orange : .cyan,
                                              lineWidth: 2)
                                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                                .frame(width: 13, height: 13)
                            Text(input.name)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            Spacer()
                        }
                        .frame(height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Connect to \(module.title): \(input.name) [\(input.signal.rawValue)]")
                }
            }
            Spacer(minLength: 0)
            if module.isOutputAvailable {
                Text("OUT  ·  \(module.signal == .audio ? "AUDIO" : "CV")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelectedSource ? accent : accent.opacity(0.35),
                              lineWidth: isSelectedSource ? 2 : 1)
        }
        .overlay(alignment: .trailing) {
            if module.isOutputAvailable {
                Button(action: onOutput) {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle().strokeBorder(accent, lineWidth: 3)
                        }
                        .overlay {
                            Circle().fill(isSelectedSource ? accent : .clear)
                                .frame(width: 9, height: 9)
                        }
                }
                .buttonStyle(.plain)
                .offset(x: 11)
                .help("Select \(module.title) \(module.signal.rawValue) output")
            }
        }
    }
}
