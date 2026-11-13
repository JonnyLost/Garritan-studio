import SwiftUI
import DAWCore

/// Stage placement is independent of the sample library. Horizontal placement
/// controls existing track pan; L1-L5 drive the shared Concert Hall send.
struct OrchestralStageView: View {
    @Environment(\.studioPalette) private var palette
    @ObservedObject var viewModel: ProjectViewModel
    var expanded: Bool = false
    @State private var dragOrigins: [TrackID: CGPoint] = [:]
    @State private var showAcousticRoomDesigner = false
    private var selectedLayout: StageLayout {
        StageLayout(rawValue: viewModel.project.dawState.stageLayoutID ?? "") ?? .symphony
    }

    private var layoutBinding: Binding<StageLayout> {
        Binding(
            get: { selectedLayout },
            set: { layout in
                viewModel.project.dawState.stageLayoutID = layout.rawValue
            }
        )
    }

    private enum StageLayout: String, CaseIterable, Identifiable {
        case filmScore = "Film Score Orchestra"
        case symphony = "Full Symphony Orchestra"
        case chamber = "Chamber Orchestra"
        case strings = "String Orchestra"
        case concertBand = "Concert Band"
        case jazz = "Jazz Band"
        case choir = "Choir"
        var id: String { rawValue }
    }

    private var instrumentTracks: [Track] {
        viewModel.project.tracks.filter { $0.type == .midi || $0.type == .instrument }
    }

    var body: some View {
        if expanded {
            expandedWorkspace
        } else {
            compactWorkspace
        }
    }

    private var compactWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Orchestral Stage").font(.headline)
                Text("Drag a marker sideways to pan and between rows to assign a reverb zone.")
                    .font(.caption).foregroundStyle(.secondary)

                GeometryReader { proxy in
                    stageCanvas(width: proxy.size.width)
                }
                .frame(height: 250)

                HStack {
                    Text("LEFT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("CONDUCTOR")
                    Text("RIGHT").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)

                acousticRoomControls
                selectedTrackControls

                Text("Stage positions and acoustic room choice are saved with the project.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    // The diagram and inspector have independent widths, so labels and
    // controls no longer stretch across the full editor.
    private var expandedWorkspace: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        StudioSectionHeading("Orchestra Seating", symbol: "music.note.list")
                        Spacer()
                        Text("CONCERT HALL")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.5)
                            .foregroundStyle(.secondary)
                        Picker("Stage Layout", selection: layoutBinding) {
                            ForEach(StageLayout.allCases) { layout in
                                Text(layout.rawValue).tag(layout)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    HStack {
                        Spacer()
                        Button("Auto Arrange") { autoArrangeTracks() }
                            .disabled(instrumentTracks.isEmpty)
                            .help("Place recognized instruments in the selected seating template")
                    }
                    .font(.caption)
                    fittedCurvedStage(
                        availableWidth: max(200, geometry.size.width - 328),
                        availableHeight: max(220, geometry.size.height - 66)
                    )
                    HStack(spacing: 14) {
                        Text("AUDIENCE LEFT")
                        Spacer()
                        Text("L1 DRY  ·  L5 WET")
                        Spacer()
                        Text("AUDIENCE RIGHT")
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView(.vertical) {
                  VStack(alignment: .leading, spacing: 14) {
                    acousticRoomControls
                    Divider()
                    StudioSectionHeading("Instrument Position", symbol: "slider.horizontal.3")
                    selectedTrackControls
                    Divider()
                    Text("REVERB ZONES")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    ForEach(1...5, id: \.self) { zone in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(zoneColor(zone))
                                .frame(width: 9, height: 9)
                            Text("L\(zone)")
                                .font(.caption.weight(.semibold))
                                .frame(width: 24, alignment: .leading)
                            Text(zoneDescription(zone))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("All instruments share one Concert Hall. Stage position controls stereo placement, distance and ambience.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                  }
                  .padding(14)
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                // GeometryReader does not constrain the ScrollView's height
                // automatically in every split-editor configuration. Give it
                // the available viewport so the bottom rows remain scrollable.
                .frame(width: 280, height: max(120, geometry.size.height - 24))
                .studioPanel()
            }
            .padding(14)
        }
        .background(palette.canvas)
        .tint(palette.accent)
    }

    /// Conservative name-based matching. Unrecognized instruments retain their
    /// current position; the command is explicit, never triggered by a picker change.
    private func autoArrangeTracks() {
        let sections = seating
        for track in instrumentTracks {
            let name = track.name.lowercased()
            let matches = sections.filter { section in
                let label = section.name.lowercased()
                let aliases: [String]
                if name.contains("violin") {
                    aliases = name.contains("ii") || name.contains("2") ? ["violin ii"] : ["violin i"]
                } else if name.contains("viola") { aliases = ["viola"]
                } else if name.contains("cello") { aliases = ["cello"]
                } else if name.contains("bassoon") { aliases = ["bassoon"]
                } else if name.contains("clarinet") { aliases = ["clarinet"]
                } else if name.contains("flute") || name.contains("piccolo") { aliases = ["flute", "picc"]
                } else if name.contains("oboe") { aliases = ["oboe"]
                } else if name.contains("horn") { aliases = ["horn"]
                } else if name.contains("trumpet") { aliases = ["trumpet"]
                } else if name.contains("trombone") { aliases = ["trombone"]
                } else if name.contains("tuba") { aliases = ["tuba"]
                } else if name.contains("timpani") { aliases = ["timp"]
                } else if name.contains("harp") { aliases = ["harp"]
                } else if name.contains("soprano") { aliases = ["soprano"]
                } else if name.contains("alto") { aliases = ["alto"]
                } else if name.contains("tenor") { aliases = ["tenor"]
                } else if name.contains("choir") { aliases = ["choir"]
                } else if name.contains("piano") { aliases = ["piano"]
                } else if name.contains("guitar") { aliases = ["guitar"]
                } else if name.contains("drum") { aliases = ["drum", "perc"]
                } else if name.contains("sax") { aliases = ["sax"]
                } else if name.contains("bass") { aliases = ["bass"]
                } else { aliases = [] }
                return aliases.contains { label.contains($0) }
            }
            guard let section = matches.first else { continue }
            viewModel.setTrackStagePosition(
                id: track.id,
                pan: Float(section.pan),
                zone: section.zone
            )
        }
    }

    private func zoneDescription(_ zone: Int) -> String {
        switch zone {
        case 1: return "Close / direct"
        case 2: return "Light ambience"
        case 3: return "Balanced room"
        case 4: return "Distant"
        default: return "Deep hall"
        }
    }

    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: return Color(red: 0.35, green: 0.65, blue: 0.55)
        case 2: return Color(red: 0.40, green: 0.60, blue: 0.70)
        case 3: return Color(red: 0.65, green: 0.59, blue: 0.45)
        case 4: return Color(red: 0.48, green: 0.55, blue: 0.71)
        default: return Color(red: 0.50, green: 0.48, blue: 0.66)
        }
    }

    private func fittedCurvedStage(availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let referenceWidth: CGFloat = 1000
        let referenceHeight: CGFloat = 560
        let scale = max(0.1, min(
            (availableWidth - 12) / referenceWidth,
            (availableHeight - 12) / referenceHeight
        ))
        return curvedStageCanvas(width: referenceWidth)
            .frame(width: referenceWidth, height: referenceHeight)
            .scaleEffect(scale, anchor: .center)
            .frame(width: availableWidth, height: availableHeight)
    }

    // Seating map transcribed from the original sketch. These are visual
    // section guides, not project tracks or automatic instrument assignments.
    private struct SeatSection: Identifiable {
        let name: String
        let zone: Int
        let pan: CGFloat
        let span: CGFloat
        var id: String { "\(zone)-\(name)" }
    }

    private let symphonySeating: [SeatSection] = [
        .init(name: "Violin I", zone: 1, pan: -0.77, span: 0.40),
        .init(name: "Violin II", zone: 1, pan: -0.37, span: 0.35),
        .init(name: "Viola", zone: 1, pan: 0.00, span: 0.34),
        .init(name: "Cello", zone: 1, pan: 0.40, span: 0.37),
        .init(name: "Basses", zone: 1, pan: 0.78, span: 0.39),
        .init(name: "Harp", zone: 2, pan: -0.86, span: 0.23),
        .init(name: "Picc.", zone: 2, pan: -0.64, span: 0.18),
        .init(name: "Flutes", zone: 2, pan: -0.38, span: 0.31),
        .init(name: "Oboes", zone: 2, pan: -0.05, span: 0.29),
        .init(name: "Eng. Horn", zone: 2, pan: 0.21, span: 0.22),
        .init(name: "Bassoons", zone: 2, pan: 0.51, span: 0.36),
        .init(name: "Timp.", zone: 2, pan: 0.87, span: 0.21),
        .init(name: "World Drums", zone: 3, pan: -0.88, span: 0.22),
        .init(name: "Clarinet", zone: 3, pan: -0.62, span: 0.27),
        .init(name: "Trumpets", zone: 3, pan: -0.25, span: 0.36),
        .init(name: "Horns", zone: 3, pan: 0.10, span: 0.30),
        .init(name: "Trombones", zone: 3, pan: 0.48, span: 0.35),
        .init(name: "Tuba", zone: 3, pan: 0.83, span: 0.25),
        .init(name: "Taiko", zone: 4, pan: -0.88, span: 0.24),
        .init(name: "Snare / Cym.", zone: 4, pan: -0.54, span: 0.35),
        .init(name: "Aux. Perc.", zone: 4, pan: -0.12, span: 0.35),
        .init(name: "World Drums", zone: 4, pan: 0.38, span: 0.40),
        .init(name: "Taiko", zone: 4, pan: 0.84, span: 0.25),
        .init(name: "Sopranos", zone: 5, pan: -0.82, span: 0.29),
        .init(name: "Altos", zone: 5, pan: -0.43, span: 0.30),
        .init(name: "Choir / Organ", zone: 5, pan: 0.0, span: 0.46),
        .init(name: "Tenors", zone: 5, pan: 0.43, span: 0.30),
        .init(name: "Basses", zone: 5, pan: 0.82, span: 0.29)
    ]

    // Visual seating templates; changing them does not move project tracks.
    private var seating: [SeatSection] {
        switch selectedLayout {
        case .symphony: return symphonySeating
        case .filmScore: return [
            .init(name: "Violin I", zone: 1, pan: -0.78, span: 0.40),
            .init(name: "Violin II", zone: 1, pan: -0.36, span: 0.35),
            .init(name: "Violas", zone: 1, pan: 0.03, span: 0.34),
            .init(name: "Cellos", zone: 1, pan: 0.43, span: 0.37),
            .init(name: "Basses", zone: 1, pan: 0.80, span: 0.35),
            .init(name: "Harp / Piano", zone: 2, pan: -0.83, span: 0.30),
            .init(name: "Flutes", zone: 2, pan: -0.50, span: 0.26),
            .init(name: "Oboes", zone: 2, pan: -0.21, span: 0.26),
            .init(name: "Clarinets", zone: 2, pan: 0.12, span: 0.28),
            .init(name: "Bassoons", zone: 2, pan: 0.46, span: 0.30),
            .init(name: "Timpani", zone: 2, pan: 0.83, span: 0.25),
            .init(name: "Trumpets", zone: 3, pan: -0.63, span: 0.34),
            .init(name: "Horns", zone: 3, pan: -0.21, span: 0.40),
            .init(name: "Trombones", zone: 3, pan: 0.29, span: 0.39),
            .init(name: "Tuba", zone: 3, pan: 0.75, span: 0.30),
            .init(name: "Orch. Perc.", zone: 4, pan: -0.70, span: 0.43),
            .init(name: "Taiko / Drums", zone: 4, pan: -0.20, span: 0.40),
            .init(name: "Hybrid Perc.", zone: 4, pan: 0.34, span: 0.44),
            .init(name: "Synth / FX", zone: 4, pan: 0.81, span: 0.29),
            .init(name: "Sopranos", zone: 5, pan: -0.77, span: 0.34),
            .init(name: "Altos", zone: 5, pan: -0.36, span: 0.34),
            .init(name: "Choir", zone: 5, pan: 0.05, span: 0.32),
            .init(name: "Tenors", zone: 5, pan: 0.44, span: 0.32),
            .init(name: "Basses", zone: 5, pan: 0.81, span: 0.30)
        ]
        case .chamber: return [
            .init(name: "Violin I", zone: 1, pan: -0.65, span: 0.55),
            .init(name: "Violin II", zone: 1, pan: -0.1, span: 0.42),
            .init(name: "Viola", zone: 1, pan: 0.35, span: 0.4),
            .init(name: "Cello", zone: 1, pan: 0.76, span: 0.38),
            .init(name: "Basses", zone: 2, pan: 0.79, span: 0.3),
            .init(name: "Flutes", zone: 2, pan: -0.57, span: 0.32),
            .init(name: "Oboes", zone: 2, pan: -0.18, span: 0.32),
            .init(name: "Clarinets", zone: 2, pan: 0.19, span: 0.32),
            .init(name: "Bassoons", zone: 2, pan: 0.52, span: 0.3),
            .init(name: "Horns", zone: 3, pan: -0.4, span: 0.42),
            .init(name: "Trumpets", zone: 3, pan: 0.13, span: 0.34),
            .init(name: "Timpani", zone: 4, pan: 0.43, span: 0.34)
        ]
        case .strings: return [
            .init(name: "Violin I", zone: 1, pan: -0.72, span: 0.53),
            .init(name: "Violin II", zone: 1, pan: -0.19, span: 0.47),
            .init(name: "Viola", zone: 1, pan: 0.3, span: 0.43),
            .init(name: "Cello", zone: 1, pan: 0.74, span: 0.42),
            .init(name: "Double Basses", zone: 2, pan: 0.6, span: 0.53)
        ]
        case .concertBand: return [
            .init(name: "Flutes / Picc.", zone: 1, pan: -0.7, span: 0.48),
            .init(name: "Clarinets", zone: 1, pan: -0.1, span: 0.62),
            .init(name: "Saxophones", zone: 1, pan: 0.62, span: 0.52),
            .init(name: "Oboes", zone: 2, pan: -0.73, span: 0.38),
            .init(name: "Bassoons", zone: 2, pan: -0.28, span: 0.37),
            .init(name: "Horns", zone: 2, pan: 0.22, span: 0.44),
            .init(name: "Euphoniums", zone: 2, pan: 0.74, span: 0.4),
            .init(name: "Trumpets", zone: 3, pan: -0.52, span: 0.56),
            .init(name: "Trombones", zone: 3, pan: 0.15, span: 0.56),
            .init(name: "Tubas", zone: 3, pan: 0.78, span: 0.35),
            .init(name: "Percussion", zone: 4, pan: -0.3, span: 0.7),
            .init(name: "Timpani", zone: 4, pan: 0.57, span: 0.42)
        ]
        case .jazz: return [
            .init(name: "Saxophones", zone: 1, pan: -0.46, span: 0.86),
            .init(name: "Trombones", zone: 2, pan: -0.38, span: 0.77),
            .init(name: "Trumpets", zone: 3, pan: -0.38, span: 0.77),
            .init(name: "Piano", zone: 1, pan: 0.72, span: 0.33),
            .init(name: "Bass", zone: 2, pan: 0.67, span: 0.34),
            .init(name: "Drums", zone: 3, pan: 0.67, span: 0.36),
            .init(name: "Guitar", zone: 4, pan: 0.67, span: 0.36)
        ]
        case .choir: return [
            .init(name: "Sopranos", zone: 2, pan: -0.7, span: 0.48),
            .init(name: "Altos", zone: 2, pan: -0.21, span: 0.45),
            .init(name: "Tenors", zone: 2, pan: 0.26, span: 0.43),
            .init(name: "Basses", zone: 2, pan: 0.73, span: 0.43),
            .init(name: "Organ / Piano", zone: 4, pan: 0, span: 0.42)
        ]
        }
    }

    // All geometry is in a 1000 x 560 reference canvas. The complete stage
    // scales with its width instead of being clipped by a fixed-height editor.
    private func stageScale(_ width: CGFloat) -> CGFloat {
        width / 1000
    }

    private func stagePoint(pan: CGFloat, zone: Int, width: CGFloat) -> CGPoint {
        let angle = pan * (.pi / 2)
        let radius = CGFloat(105 + (zone - 1) * 83)
        let scale = stageScale(width)
        return CGPoint(
            x: width / 2 + sin(angle) * radius * scale,
            y: (535 - cos(angle) * radius) * scale
        )
    }

    private func curvedStageCanvas(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.surface)

            ForEach((1...5).reversed(), id: \.self) { zone in
                orchestralBand(zone, width: width)
            }
            ForEach(seating) { section in
                seatingSection(section, width: width)
            }
            ForEach(instrumentTracks) { track in
                curvedMarker(track, width: width)
            }
            conductorPodium(width: width)
        }
        .frame(height: 560 * stageScale(width))
        .clipped()
    }

    // The conductor occupies the open center of the front string arc,
    // rather than appearing as a label below the drawing.
    private func conductorPodium(width: CGFloat) -> some View {
        let scale = stageScale(width)
        return VStack(spacing: 5 * scale) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.19, green: 0.25, blue: 0.31))
                    .frame(width: 47 * scale, height: 47 * scale)
                Circle()
                    .stroke(Color(red: 0.73, green: 0.78, blue: 0.82).opacity(0.8),
                            lineWidth: 2 * scale)
                    .frame(width: 47 * scale, height: 47 * scale)
                Image(systemName: "figure.stand")
                    .font(.system(size: 23 * scale, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
            }
            Text("CONDUCTOR · DRY")
                .font(.system(size: 12 * scale, weight: .semibold))
                .tracking(1.2 * scale)
                .foregroundStyle(.secondary)
        }
        .position(x: width / 2, y: 493 * scale)
        .allowsHitTesting(false)
    }

    private func orchestralBand(_ zone: Int, width: CGFloat) -> some View {
        let scale = stageScale(width)
        return Path { path in
            for step in 0...120 {
                let pan = CGFloat(step) / 60 - 1
                let point = stagePoint(pan: pan, zone: zone, width: width)
                if step == 0 { path.move(to: point) }
                else { path.addLine(to: point) }
            }
        }
        .stroke(
            zoneColor(zone).opacity(0.10),
            style: StrokeStyle(lineWidth: 74 * scale, lineCap: .butt)
        )
        .overlay(
            Text("L\(zone)")
                .font(.system(size: 13 * scale, weight: .bold))
                .foregroundStyle(.secondary)
                .position(stagePoint(pan: -0.99, zone: zone, width: width))
        )
    }

    // Each instrument section is an individual annular sector rather than
    // a label sitting on a broad stripe. The seating chart is a guide only.
    private func seatingSection(_ section: SeatSection, width: CGFloat) -> some View {
        let point = stagePoint(pan: section.pan, zone: section.zone, width: width)
        let scale = stageScale(width)
        return ZStack {
            sectionOutline(section, width: width)
                .fill(zoneColor(section.zone).opacity(0.15))
            sectionOutline(section, width: width)
                .stroke(zoneColor(section.zone).opacity(0.65), lineWidth: 1.3 * scale)
            Text(section.name)
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: max(42, section.span * 190 * scale))
                .position(point)
                .allowsHitTesting(false)
        }
    }

    private func sectionOutline(_ section: SeatSection, width: CGFloat) -> Path {
        let centerX = width / 2
        let centerY = 535 * stageScale(width)
        let scale = stageScale(width)
        let innerRadius = CGFloat(105 + (section.zone - 1) * 83 - 34) * scale
        let outerRadius = CGFloat(105 + (section.zone - 1) * 83 + 34) * scale
        let start = (section.pan - section.span / 2) * (.pi / 2)
        let end = (section.pan + section.span / 2) * (.pi / 2)
        var path = Path()
        let segments = 16
        for step in 0...segments {
            let angle = start + (end - start) * CGFloat(step) / CGFloat(segments)
            let point = CGPoint(x: centerX + sin(angle) * outerRadius,
                                y: centerY - cos(angle) * outerRadius)
            if step == 0 { path.move(to: point) }
            else { path.addLine(to: point) }
        }
        for step in (0...segments).reversed() {
            let angle = start + (end - start) * CGFloat(step) / CGFloat(segments)
            path.addLine(to: CGPoint(x: centerX + sin(angle) * innerRadius,
                                     y: centerY - cos(angle) * innerRadius))
        }
        path.closeSubpath()
        return path
    }

    private func curvedMarker(_ track: Track, width: CGFloat) -> some View {
        let isConductor = track.stageReverbZone == 0
        let point = isConductor
            ? CGPoint(x: width / 2, y: 477 * stageScale(width))
            : stagePoint(pan: CGFloat(track.pan), zone: track.stageReverbZone ?? 2, width: width)
        return Circle()
            .fill(viewModel.selectedTrackID == track.id ? Color.accentColor : Color.orange)
            .frame(width: 25, height: 25)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .overlay(
                Text(String(track.name.prefix(1)))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
            .position(point)
            .help(track.stageReverbZone == 0 ? "\(track.name) — Conductor (center, dry)" : "\(track.name) — L\(track.stageReverbZone ?? 2)")
            .onTapGesture { viewModel.selectTrack(track.id) }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        moveCurvedMarker(
                            trackID: track.id,
                            current: point,
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
        let scale = stageScale(width)
        let dx = (start.x + translation.width - width / 2) / scale
        let dy = 535 - (start.y + translation.height) / scale
        let angle = atan2(dx, dy)
        let pan = Float(min(CGFloat(1), max(CGFloat(-1), angle / (.pi / 2))))
        let radius = hypot(dx, dy)
        // Drop inside the innermost string arc to snap to the conductor.
        if radius < 72 {
            viewModel.setTrackStagePosition(id: trackID, pan: 0, zone: 0)
        } else {
            let zone = min(5, max(1, Int(((radius - 105) / 83).rounded()) + 1))
            viewModel.setTrackStagePosition(id: trackID, pan: pan, zone: zone)
        }
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
        let y = CGFloat(35 + (max(1, track.stageReverbZone ?? 2) - 1) * 43)
        let selected = viewModel.selectedTrackID == track.id

        return Circle()
            .fill(selected ? palette.accent : Color.orange)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .overlay(
                Text(String(track.name.prefix(1)))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            )
            .position(x: x, y: y)
            .help("\(track.name) — L\(track.stageReverbZone ?? 2)")
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
                    .disabled(track.stageReverbZone == 0)
                Text("\(Int(track.pan * 100))")
                    .monospacedDigit()
                    .frame(width: 36)
            }
            Picker("Reverb zone", selection: zoneBinding(for: id)) {
                Text("Conductor · Dry").tag(0)
                ForEach(1...5, id: \.self) { zone in
                    Text("L\(zone)").tag(zone)
                }
            }
            Text("Moving the instrument changes its direct level and hall send.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Instrument Wet")
                    Spacer()
                    Text("\(Int(effectiveWetLevel(for: track) * 100))%")
                        .monospacedDigit()
                }
                Slider(value: wetLevelBinding(for: id), in: 0...1)
                    .disabled(track.stageReverbZone == 0)
            }
            Text("The wet level follows stage movement; adjust it to fine-tune the instrument.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Overall Reverb")
                    Spacer()
                    Text("\(Int(viewModel.audioEngine.concertHallOverallReverb * 100))%")
                        .monospacedDigit()
                }
                Slider(value: overallReverbBinding, in: 0...2)
            }
            Text("Overall Reverb affects the entire Concert Hall.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Select a MIDI or instrument track to edit its stage position.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Acoustic-space selection is separate from orchestra seating layouts.
    /// The original Concert Hall remains available for existing projects.
    private var acousticRoomControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ROOM ACOUSTICS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Picker("Acoustic Space", selection: acousticRoomBinding) {
                Text("Apple · Medium Hall (Legacy)").tag("apple-medium-hall")
                ForEach(StudioRoomAcousticProfile.playableProfiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(!viewModel.isEngineReady ||
                      viewModel.transportState.isPlaying ||
                      viewModel.transportState.isRecording ||
                      viewModel.isRecording)
            DisclosureGroup("Design a Custom Acoustic Room",
                            isExpanded: $showAcousticRoomDesigner) {
                StudioAcousticRoomDesignerView(viewModel: viewModel)
                    .padding(.top, 8)
            }
            .font(.caption.weight(.medium))
            Text("Native rooms are experimental acoustic interpretations. Change rooms while stopped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = viewModel.acousticRoomSelectionError {
                Text(error).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var acousticRoomBinding: Binding<String> {
        Binding(
            get: { viewModel.project.dawState.acousticRoomProfileID ?? "apple-medium-hall" },
            set: { viewModel.selectConcertHallRoom(id: $0) }
        )
    }

    private let stageSendLevels: [Double] = [0, 0.12, 0.20, 0.30, 0.43, 0.58]

    private func effectiveWetLevel(for track: Track) -> Double {
        let zone = min(5, max(0, track.stageReverbZone ?? 2))
        return min(1, stageSendLevels[zone] * Double(track.stageWetTrim ?? 1))
    }

    private func wetLevelBinding(for id: TrackID) -> Binding<Double> {
        Binding(
            get: {
                guard let track = viewModel.project.track(withID: id) else { return 0 }
                return effectiveWetLevel(for: track)
            },
            set: { level in
                guard let track = viewModel.project.track(withID: id) else { return }
                let zone = min(5, max(0, track.stageReverbZone ?? 2))
                let base = stageSendLevels[zone]
                guard base > 0 else { return }
                viewModel.setTrackStageWetTrim(id: id, trim: Float(min(2, max(0, level / base))))
            }
        )
    }

    private var overallReverbBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.audioEngine.concertHallOverallReverb) },
            set: { viewModel.setConcertHallOverallReverb(Float($0)) }
        )
    }

    private func panBinding(for id: TrackID) -> Binding<Double> {
        Binding(
            get: { Double(viewModel.project.track(withID: id)?.pan ?? 0) },
            set: { viewModel.setTrackPan(id: id, pan: Float($0)) }
        )
    }

    private func zoneBinding(for id: TrackID) -> Binding<Int> {
        Binding(
            get: { viewModel.project.track(withID: id)?.stageReverbZone ?? 2 },
            set: { viewModel.setTrackStageZone(id: id, zone: $0) }
        )
    }
}
