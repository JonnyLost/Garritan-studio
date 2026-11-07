import SwiftUI
import DAWCore

/// Stage placement is independent of the sample library. Horizontal placement
/// controls existing track pan; L1-L5 are persisted room-send zones (audio later).
struct OrchestralStageView: View {
    @ObservedObject var viewModel: ProjectViewModel
    var expanded: Bool = false
    @State private var dragOrigins: [TrackID: CGPoint] = [:]

    private var instrumentTracks: [Track] {
        viewModel.project.tracks.filter { $0.type == .midi || $0.type == .instrument }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Orchestral Stage").font(.headline)
                Text("Drag a marker sideways to pan and between rows to assign a reverb zone.")
                    .font(.caption).foregroundStyle(.secondary)

                GeometryReader { proxy in
                    if expanded {
                        curvedStageCanvas(width: proxy.size.width)
                    } else {
                        stageCanvas(width: proxy.size.width)
                    }
                }
                .frame(height: expanded ? 430 : 250)

                HStack {
                    Text("LEFT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CONDUCTOR")
                    Text("RIGHT").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)

                selectedTrackControls

                Text("Zones are saved with the project. Shared concert-hall reverb will be connected separately.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    // A five-arc stage, modeled after the original orchestral seating sketch.
    // L5 is at the back; L1 is closest to the conductor.
    private func curvedStageCanvas(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
            ForEach(1...5, id: \.self) { zone in
                curvedZone(zone, width: width)
            }
            ForEach(instrumentTracks) { track in
                curvedMarker(track, width: width)
            }
            Text("CONDUCTOR")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .position(x: width / 2, y: 410)
        }
    }

    private func curveY(zone: Int, x: CGFloat, width: CGFloat) -> CGFloat {
        let centerY = CGFloat(75 + (5 - zone) * 65)
        let normalizedX = (x - width / 2) / max(1, width / 2)
        return centerY + 34 * normalizedX * normalizedX
    }

    private func curvedZone(_ zone: Int, width: CGFloat) -> some View {
        let centerY = curveY(zone: zone, x: width / 2, width: width)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: 24, y: centerY + 34))
                path.addQuadCurve(
                    to: CGPoint(x: width - 24, y: centerY + 34),
                    control: CGPoint(x: width / 2, y: centerY - 34)
                )
            }
            .stroke(
                zone.isMultiple(of: 2) ? Color.blue.opacity(0.17) : Color.teal.opacity(0.17),
                style: StrokeStyle(lineWidth: 45, lineCap: .round)
            )
            Text("L\(zone)")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .position(x: 24, y: curveY(zone: zone, x: 24, width: width))
        }
    }

    private func curvedMarker(_ track: Track, width: CGFloat) -> some View {
        let usableWidth = max(CGFloat(1), width - 70)
        let x = CGFloat(35) + CGFloat((track.pan + 1) / 2) * usableWidth
        let y = curveY(zone: track.stageReverbZone ?? 1, x: x, width: width)
        return Circle()
            .fill(viewModel.selectedTrackID == track.id ? Color.accentColor : Color.orange)
            .frame(width: 25, height: 25)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .overlay(
                Text(String(track.name.prefix(1)))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
            .position(x: x, y: y)
            .help("\(track.name) — L\(track.stageReverbZone ?? 1)")
            .onTapGesture { viewModel.selectTrack(track.id) }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        moveCurvedMarker(
                            trackID: track.id,
                            current: CGPoint(x: x, y: y),
                            translation: value.translation,
                            width: width
                        )
                    }
                    .onEnded { _ in dragOrigins.removeValue(forKey: track.id) }
            )
    }

    private func moveCurvedMarker(
        trackID: TrackID,
        current: CGPoint,
        translation: CGSize,
        width: CGFloat
    ) {
        if dragOrigins[trackID] == nil { dragOrigins[trackID] = current }
        guard let start = dragOrigins[trackID] else { return }
        let x = min(width - 35, max(CGFloat(35), start.x + translation.width))
        let pan = Float((x - 35) / max(1, width - 70) * 2 - 1)
        let y = start.y + translation.height
        let nearestZone = (1...5).min {
            abs(curveY(zone: $0, x: x, width: width) - y) <
            abs(curveY(zone: $1, x: x, width: width) - y)
        } ?? 1
        viewModel.setTrackStagePosition(id: trackID, pan: pan, zone: nearestZone)
    }

    private func stageCanvas(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))

            ForEach(1...5, id: \.self) { zone in
                zoneRow(zone, width: width)
            }

            Path { path in
                path.move(to: CGPoint(x: width / 2, y: 14))
                path.addLine(to: CGPoint(x: width / 2, y: 238))
            }
            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            ForEach(instrumentTracks) { track in
                marker(track, width: width)
            }
        }
    }

    private func zoneRow(_ zone: Int, width: CGFloat) -> some View {
        let y = CGFloat(35 + (zone - 1) * 43)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(zone.isMultiple(of: 2) ? Color.blue.opacity(0.08) : Color.teal.opacity(0.08))
            Text("L\(zone)")
                .font(.caption2).bold()
                .padding(.leading, 7)
        }
        .frame(height: 40)
        .position(x: width / 2, y: y)
    }

    private func marker(_ track: Track, width: CGFloat) -> some View {
        let usableWidth = max(CGFloat(1), width - 36)
        let x = CGFloat(18) + CGFloat((track.pan + 1) / 2) * usableWidth
        let y = CGFloat(35 + ((track.stageReverbZone ?? 1) - 1) * 43)
        let selected = viewModel.selectedTrackID == track.id

        return Circle()
            .fill(selected ? Color.accentColor : Color.orange)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .overlay(
                Text(String(track.name.prefix(1)))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            )
            .position(x: x, y: y)
            .help("\(track.name) — L\(track.stageReverbZone ?? 1)")
            .onTapGesture { viewModel.selectTrack(track.id) }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        moveMarker(
                            trackID: track.id,
                            current: CGPoint(x: x, y: y),
                            translation: value.translation,
                            usableWidth: usableWidth
                        )
                    }
                    .onEnded { _ in
                        dragOrigins.removeValue(forKey: track.id)
                    }
            )
    }

    private func moveMarker(
        trackID: TrackID,
        current: CGPoint,
        translation: CGSize,
        usableWidth: CGFloat
    ) {
        // The model updates continuously while dragging, so capture the first
        // coordinate only once; otherwise every update compounds translation.
        if dragOrigins[trackID] == nil {
            dragOrigins[trackID] = current
        }
        guard let start = dragOrigins[trackID] else { return }
        let proposedX = start.x + translation.width
        let normalized = (proposedX - 18) / usableWidth
        let rawPan = normalized * 2 - 1
        let clamped = min(CGFloat(1), max(CGFloat(-1), rawPan))
        let proposedY = start.y + translation.height
        let rawZone = (proposedY - 35) / 43
        let zone = min(5, max(1, Int(rawZone.rounded()) + 1))
        viewModel.setTrackStagePosition(id: trackID, pan: Float(clamped), zone: zone)
    }

    @ViewBuilder
    private var selectedTrackControls: some View {
        if let id = viewModel.selectedTrackID,
           let track = viewModel.project.track(withID: id),
           track.type == .midi || track.type == .instrument {
            Divider()
            Text(track.name).font(.subheadline).bold()
            HStack {
                Text("Pan")
                Slider(value: panBinding(for: id), in: -1...1)
                Text("\(Int(track.pan * 100))")
                    .monospacedDigit()
                    .frame(width: 36)
            }
            Picker("Reverb zone", selection: zoneBinding(for: id)) {
                ForEach(1...5, id: \.self) { zone in
                    Text("L\(zone)").tag(zone)
                }
            }
            Text("L1 = least reverb · L5 = most reverb")
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("Select a MIDI or instrument track to edit its stage position.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func panBinding(for id: TrackID) -> Binding<Double> {
        Binding(
            get: { Double(viewModel.project.track(withID: id)?.pan ?? 0) },
            set: { viewModel.setTrackPan(id: id, pan: Float($0)) }
        )
    }

    private func zoneBinding(for id: TrackID) -> Binding<Int> {
        Binding(
            get: { viewModel.project.track(withID: id)?.stageReverbZone ?? 1 },
            set: { viewModel.setTrackStageZone(id: id, zone: $0) }
        )
    }
}
