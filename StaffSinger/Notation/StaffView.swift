//
//  StaffView.swift
//  StaffSinger
//
//  A clean two-measure music sheet, centered both ways in whatever space
//  it's given. Press the staff to place a note: a faint ghost follows the
//  finger and the note commits when the finger lifts.
//

import SwiftUI
import UIKit

struct StaffView: View {
    @ObservedObject var vm: ScoreViewModel
    @ObservedObject var audio: AudioEngine

    private let lineSpacing: CGFloat = 18
    private let noteRadius: CGFloat = 7

    // Live preview while a finger is pressed on the staff. The note is only
    // committed when the finger lifts; until then we show a faint ghost and
    // sound/buzz each time the pitch under the finger changes.
    @State private var previewPitch: Pitch? = nil
    /// Pitch currently under the finger while dragging an existing note.
    @State private var movingPitch: Pitch? = nil
    @State private var haptics = UISelectionFeedbackGenerator()
    @State private var commitHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var deleteHaptic = UIImpactFeedbackGenerator(style: .heavy)
    @State private var editHaptic = UIImpactFeedbackGenerator(style: .medium)

    /// The note whose long-press editor (change length / delete) is open, and
    /// the on-screen point its glyph sits at (so the popover can anchor to it).
    @State private var editingNoteID: UUID? = nil
    @State private var editingAnchor: CGPoint = .zero

    private let staffSpace = "staff"

    /// Geometry for exactly two measures, centered in the given width.
    private struct Metrics {
        let leftEdge: CGFloat     // where the staff lines start
        let rightEdge: CGFloat    // where the staff lines (final barline) end
        let musicStartX: CGFloat  // x of beat 0 (just after the time signature)
        let beatWidth: CGFloat    // px per quarter-note beat
        let measureBeats: CGFloat // quarter beats in one measure
        var beatLimit: CGFloat { measureBeats * 2 }   // two measures
    }

    private func metrics(width: CGFloat) -> Metrics {
        let sideMargin: CGFloat = 30
        // Widen the clef gutter to make room for the key-signature accidentals.
        let keyCount = min(7, abs(vm.score.keySignature))
        let clefSpace: CGFloat = 56 + CGFloat(keyCount) * 12
        let measureBeats = max(1, CGFloat(vm.score.quarterBeatsPerMeasure))
        let leftEdge = sideMargin
        let rightEdge = width - sideMargin
        let musicStartX = leftEdge + clefSpace
        let beatWidth = (rightEdge - musicStartX) / (2 * measureBeats)
        return Metrics(leftEdge: leftEdge, rightEdge: rightEdge,
                       musicStartX: musicStartX, beatWidth: beatWidth,
                       measureBeats: measureBeats)
    }

    var body: some View {
        GeometryReader { geo in
            // Center the five staff lines vertically in the available height.
            let topLineY = max(lineSpacing * 2,
                               (geo.size.height - 4 * lineSpacing) / 2)
            let layout = StaffLayout(lineSpacing: lineSpacing, topLineY: topLineY)
            let m = metrics(width: geo.size.width)
            let beams = beamData(layout: layout, m: m)

            ZStack(alignment: .topLeading) {
                staffLines(layout: layout, m: m)
                barlines(layout: layout, m: m)
                clef(layout: layout, m: m)
                keySignatureView(layout: layout, m: m)
                tapCatcher(layout: layout)        // empty-staff taps (add) — below notes
                beamLayer(beams.groups, layout: layout)             // stems + beams
                noteLayer(layout: layout, m: m,
                          beamedIDs: beams.beamedIDs)               // notes on top
                ghostLayer(layout: layout, m: m)
                measureWarnings(layout: layout, m: m)  // red barline + "초과" badge
                editorOverlay(geo: geo)           // long-press editor — top-most
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: staffSpace)
        }
        .background(Color.white)
    }

    // MARK: - Staff lines

    private func staffLines(layout: StaffLayout, m: Metrics) -> some View {
        Canvas { ctx, _ in
            for y in layout.lineYs {
                var path = Path()
                path.move(to: CGPoint(x: m.leftEdge, y: y))
                path.addLine(to: CGPoint(x: m.rightEdge, y: y))
                ctx.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 1)
            }
        }
    }

    // MARK: - Barlines (start, middle, final) for exactly two measures

    private func barlines(layout: StaffLayout, m: Metrics) -> some View {
        Canvas { ctx, _ in
            let top = layout.lineYs.first ?? layout.topLineY
            let bottom = layout.bottomLineY

            func bar(at x: CGFloat, width: CGFloat) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
                ctx.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: width)
            }

            // Opening barline, end of measure 1, and a heavier final barline.
            bar(at: m.musicStartX, width: 1)
            bar(at: m.musicStartX + m.measureBeats * m.beatWidth, width: 1)
            bar(at: m.rightEdge, width: 2.5)
        }
    }

    // MARK: - Treble clef + time signature

    private func clef(layout: StaffLayout, m: Metrics) -> some View {
        let midLineY = layout.topLineY + 2 * layout.lineSpacing
        return ZStack(alignment: .topLeading) {
            Text("\u{1D11E}") // 𝄞 treble clef
                .font(.system(size: 84))
                .foregroundColor(.black)
                // The glyph's visual center sits ~10pt below its text-box
                // center, so offset the box up to land exactly on the middle
                // line (measured against the rendered staff).
                .position(x: m.leftEdge + 18, y: midLineY - 6)

            VStack(spacing: -6) {
                Text("\(vm.score.beatsPerMeasure)")
                Text("\(vm.score.beatUnit)")
            }
            .font(.system(size: 27, weight: .bold, design: .serif))
            .foregroundColor(.black)
            .position(x: m.musicStartX - 18, y: layout.topLineY + 2 * layout.lineSpacing)
        }
    }

    // MARK: - Key signature (accidentals after the clef)

    @ViewBuilder
    private func keySignatureView(layout: StaffLayout, m: Metrics) -> some View {
        let count = vm.score.keySignature
        if count != 0 {
            let n = min(7, abs(count))
            let useFlats = count < 0
            let refs = useFlats ? KeySignature.flatRefMidi : KeySignature.sharpRefMidi
            let glyph = useFlats ? "\u{266D}" : "\u{266F}"   // ♭ / ♯
            ForEach(0..<n, id: \.self) { i in
                let yy = layout.y(for: Pitch(midi: refs[i]))
                Text(glyph)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.black)
                    .position(x: m.leftEdge + 40 + CGFloat(i) * 12,
                              y: useFlats ? yy - 3 : yy)
            }
        }
    }

    // MARK: - Measure overflow warnings

    /// Flag any visible measure that holds more than one bar's worth of beats
    /// (the "5 beats in a 4/4 bar" case): a red closing barline and a badge.
    @ViewBuilder
    private func measureWarnings(layout: StaffLayout, m: Metrics) -> some View {
        let cap = vm.score.measureCapacity
        let loads = vm.score.measureLoads()
        ForEach(0..<2, id: \.self) { idx in
            let load = loads[idx] ?? 0
            if cap > 0, load > cap + 0.0001 {
                let x0 = m.musicStartX + CGFloat(idx) * m.measureBeats * m.beatWidth
                let x1 = x0 + m.measureBeats * m.beatWidth
                let midY = layout.topLineY + 2 * layout.lineSpacing

                // Closing barline of the overfilled measure, in red.
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2.5, height: 4 * layout.lineSpacing)
                    .position(x: x1, y: midY)

                // Badge above the measure.
                Text("⚠︎ \(beatText(load))/\(beatText(cap))박")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
                    .foregroundColor(.white)
                    .position(x: (x0 + x1) / 2, y: layout.topLineY - 18)
            }
        }
    }

    /// Compact beat count: "4", "1.5", "4.5".
    private func beatText(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)
    }

    // MARK: - Notes (only those within the two visible measures)

    /// The start beat of the group currently sounding, for the play highlight.
    private var activeBeat: Double? {
        guard let idx = audio.currentGroupIndex else { return nil }
        let groups = vm.score.chordGroups
        return idx < groups.count ? groups[idx].beat : nil
    }

    private func noteLayer(layout: StaffLayout, m: Metrics,
                           beamedIDs: Set<UUID>) -> some View {
        // Flat iteration keyed by note id keeps each note's drag stable even
        // as beats/chords shift around it.
        ForEach(vm.score.notes) { note in
            if CGFloat(note.beatOffset) < m.beatLimit {
                let x = m.musicStartX + CGFloat(note.beatOffset) * m.beatWidth + 16
                let y = layout.y(for: note.pitch)
                let isActive = activeBeat.map { abs($0 - note.beatOffset) < 0.001 } ?? false

                ZStack {
                    NoteGlyph(
                        note: note, x: x, layout: layout, radius: noteRadius,
                        isSelected: vm.selectedNoteID == note.id, isActive: isActive,
                        beamed: beamedIDs.contains(note.id),
                        keySignature: vm.score.keySignature
                    )
                    .allowsHitTesting(false)

                    // Compact hit target: tap = select, long-press = open the
                    // length/delete editor, drag = move (pitch by Y, beat by X).
                    Color.clear
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectedNoteID = note.id
                            if !note.isRest { audio.audition(note.pitch) }
                        }
                        .onLongPressGesture(minimumDuration: 0.4) {
                            editHaptic.impactOccurred()
                            vm.selectedNoteID = note.id
                            editingAnchor = CGPoint(x: x, y: y)
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                editingNoteID = note.id
                            }
                        }
                        .gesture(noteDrag(note: note, layout: layout, m: m))
                        .position(x: x, y: y)
                }
            }
        }
    }

    /// Drag an existing note: vertical changes pitch, horizontal changes beat
    /// (snapped). Sounds + buzzes whenever the pitch changes.
    private func noteDrag(note: ScoreNote, layout: StaffLayout, m: Metrics) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(staffSpace))
            .onChanged { value in
                vm.selectedNoteID = note.id
                let newPitch = vm.keyed(layout.pitch(forY: value.location.y))

                let snap = 0.5
                let raw = Double((value.location.x - m.musicStartX) / m.beatWidth)
                let beat = min(max(0, (raw / snap).rounded() * snap),
                               Double(m.beatLimit) - 0.25)

                if movingPitch != newPitch {
                    movingPitch = newPitch
                    vm.liveReadout = newPitch        // big bottom read-out
                    if !note.isRest {
                        audio.previewNote(newPitch)
                    }
                    haptics.selectionChanged()
                    haptics.prepare()
                }
                vm.moveNote(note.id, toPitch: newPitch, toBeat: beat)
            }
            .onEnded { _ in
                audio.endPreview()
                movingPitch = nil
                vm.liveReadout = nil
                commitHaptic.impactOccurred()
            }
    }

    // MARK: - Press → drag → release to add

    /// Press anywhere on the staff to start placing a note. While the finger
    /// is down we show a faint ghost at the snapped pitch and re-sound + buzz
    /// every time the pitch changes. Lifting the finger commits the note.
    private func tapCatcher(layout: StaffLayout) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let pitch = vm.keyed(layout.pitch(forY: value.location.y))
                        if previewPitch != pitch {
                            if previewPitch == nil { haptics.prepare() }
                            previewPitch = pitch
                            vm.liveReadout = pitch           // big bottom read-out
                            audio.previewNote(pitch)        // sound on change
                            haptics.selectionChanged()      // haptic on change
                            haptics.prepare()
                        }
                    }
                    .onEnded { value in
                        let committed = previewPitch ?? vm.keyed(layout.pitch(forY: value.location.y))
                        audio.endPreview()
                        previewPitch = nil
                        vm.liveReadout = nil
                        vm.addNote(pitch: committed)         // commit on release
                        commitHaptic.impactOccurred()
                    }
            )
    }

    // MARK: - Ghost preview

    /// While a finger is down we preview the note at the position it will
    /// ACTUALLY land (not under the finger), plus a full-width guide line at
    /// the chosen pitch and a clear read-out — so nothing is hidden by the hand.
    @ViewBuilder
    private func ghostLayer(layout: StaffLayout, m: Metrics) -> some View {
        if let pitch = previewPitch {
            let landingBeat = (vm.chordMode && vm.selectedNote != nil)
                ? vm.selectedNote!.beatOffset : vm.appendBeat
            let clamped = min(landingBeat, Double(m.beatLimit) - 0.25)
            let lx = m.musicStartX + CGFloat(clamped) * m.beatWidth + 16
            GhostPreview(pitch: pitch, pitchY: layout.y(for: pitch),
                         landingX: lx, leftEdge: m.leftEdge, rightEdge: m.rightEdge,
                         layout: layout, radius: noteRadius)
        }
    }

    // MARK: - Long-press editor (change length / delete)

    /// A floating card that pops up over a long-pressed note, letting the user
    /// swap its duration or delete it. Tapping anywhere else dismisses it.
    @ViewBuilder
    private func editorOverlay(geo: GeometryProxy) -> some View {
        if let id = editingNoteID,
           let note = vm.score.notes.first(where: { $0.id == id }) {
            // Dim + dismiss catcher behind the card.
            Color.black.opacity(0.06)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissEditor() }

            NoteEditorPopover(
                note: note,
                onPick: { dur in
                    editHaptic.impactOccurred()
                    vm.changeDuration(of: id, to: dur)
                },
                onAccidental: { semitones in
                    editHaptic.impactOccurred()
                    vm.changePitch(of: id, semitones: semitones)
                },
                onToggleDot: {
                    editHaptic.impactOccurred()
                    vm.toggleDot(of: id)
                },
                onDelete: {
                    deleteHaptic.impactOccurred()
                    dismissEditor()
                    vm.deleteNote(id)
                }
            )
            .position(editorPosition(in: geo.size))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    /// Anchor the card just above the note, flipping below it when there's no
    /// room, and keeping it clear of the screen edges.
    private func editorPosition(in size: CGSize) -> CGPoint {
        let halfWidth: CGFloat = 248
        let halfHeight: CGFloat = 36
        let gap: CGFloat = 64
        let x = min(max(halfWidth + 8, editingAnchor.x), size.width - halfWidth - 8)
        var y = editingAnchor.y - gap
        if y - halfHeight < 8 { y = editingAnchor.y + gap }   // not enough room above
        return CGPoint(x: x, y: y)
    }

    private func dismissEditor() {
        withAnimation(.easeOut(duration: 0.18)) { editingNoteID = nil }
    }

    // MARK: - Beaming (auto-connect eighth / sixteenth notes within a beat)

    /// One stemmed column of the music — a single note or a whole chord that
    /// shares a start beat. Beams join consecutive columns.
    private struct BeamColumn {
        let x: CGFloat
        let topY: CGFloat       // highest notehead (smallest y)
        let bottomY: CGFloat    // lowest notehead (largest y)
        let avgMidi: Double
        let isSixteenth: Bool
        let ids: [UUID]
    }

    private struct BeamGroup {
        let columns: [BeamColumn]
        let stemUp: Bool
    }

    /// Group consecutive eighth/sixteenth columns that fall in the same beat,
    /// so they can be drawn with a shared beam instead of separate flags.
    /// Returns the groups (≥2 columns each) plus the set of note ids that are
    /// beamed, so `NoteGlyph` can skip their individual stems/flags.
    private func beamData(layout: StaffLayout, m: Metrics) -> (groups: [BeamGroup], beamedIDs: Set<UUID>) {
        let columns = vm.score.chordGroups.filter { $0.beat < Double(m.beatLimit) }

        var runs: [[BeamColumn]] = []
        var current: [BeamColumn] = []
        var currentUnit: Int? = nil

        func flush() {
            if current.count >= 2 { runs.append(current) }
            current = []
            currentUnit = nil
        }

        for g in columns {
            let voiced = g.notes.filter { !$0.isRest }
            let beamable = voiced.contains { $0.duration == .eighth || $0.duration == .sixteenth }
            guard beamable else { flush(); continue }

            let unit = Int((g.beat + 0.0001).rounded(.down))   // one beam per quarter beat
            if let cu = currentUnit, cu != unit { flush() }

            let ys = voiced.map { layout.y(for: $0.pitch) }
            let col = BeamColumn(
                x: m.musicStartX + CGFloat(g.beat) * m.beatWidth + 16,
                topY: ys.min() ?? 0,
                bottomY: ys.max() ?? 0,
                avgMidi: Double(voiced.map { $0.pitch.midi }.reduce(0, +)) / Double(voiced.count),
                isSixteenth: voiced.contains { $0.duration == .sixteenth },
                ids: voiced.map { $0.id })
            current.append(col)
            currentUnit = unit
        }
        flush()

        var beamedIDs = Set<UUID>()
        let groups = runs.map { run -> BeamGroup in
            run.forEach { beamedIDs.formUnion($0.ids) }
            let avg = run.map { $0.avgMidi }.reduce(0, +) / Double(run.count)
            return BeamGroup(columns: run, stemUp: avg < 71)  // below B4 → stems up
        }
        return (groups, beamedIDs)
    }

    private func beamLayer(_ groups: [BeamGroup], layout: StaffLayout) -> some View {
        Canvas { ctx, _ in
            let reach: CGFloat = 36
            let thick: CGFloat = 4

            func rect(_ a: CGFloat, _ b: CGFloat, _ y: CGFloat) -> Path {
                Path(CGRect(x: min(a, b), y: y - thick / 2,
                            width: abs(b - a), height: thick))
            }

            for grp in groups {
                let up = grp.stemUp
                let cols = grp.columns
                func stemX(_ c: BeamColumn) -> CGFloat { up ? c.x + noteRadius - 1 : c.x - noteRadius + 1 }

                // A single horizontal beam line, beyond the outermost notehead.
                let beamY = up
                    ? (cols.map { $0.topY }.min() ?? 0) - reach
                    : (cols.map { $0.bottomY }.max() ?? 0) + reach

                // Stems from each column's far notehead up/down to the beam.
                for c in cols {
                    let attachY = up ? c.bottomY : c.topY
                    var p = Path()
                    p.move(to: CGPoint(x: stemX(c), y: attachY))
                    p.addLine(to: CGPoint(x: stemX(c), y: beamY))
                    ctx.stroke(p, with: .color(.black), lineWidth: 1.6)
                }

                // Primary beam spans the whole group.
                ctx.fill(rect(stemX(cols.first!), stemX(cols.last!), beamY),
                         with: .color(.black))

                // Secondary beam for sixteenths: full segments for runs of ≥2,
                // a short stub for an isolated sixteenth (e.g. dotted-eighth + 16th).
                let secY = beamY + (up ? thick + 2 : -(thick + 2))
                var i = 0
                while i < cols.count {
                    guard cols[i].isSixteenth else { i += 1; continue }
                    var j = i
                    while j + 1 < cols.count && cols[j + 1].isSixteenth { j += 1 }
                    if j > i {
                        ctx.fill(rect(stemX(cols[i]), stemX(cols[j]), secY), with: .color(.black))
                    } else {
                        let cx = stemX(cols[i])
                        let dir: CGFloat = i > 0 ? -1 : 1   // point toward a neighbor in the group
                        ctx.fill(rect(cx, cx + dir * 11, secY), with: .color(.black))
                    }
                    i = j + 1
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Note editor popover

private struct NoteEditorPopover: View {
    let note: ScoreNote
    let onPick: (NoteDuration) -> Void
    let onAccidental: (Int) -> Void   // semitone nudge: -1 = flat, +1 = sharp
    let onToggleDot: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Accidentals — only meaningful for real notes, not rests.
            if !note.isRest {
                accidentalButton("\u{266D}", semitones: -1)   // ♭
                Text(note.pitch.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 34)
                accidentalButton("\u{266F}", semitones: +1)   // ♯

                Divider().frame(height: 30)
            }

            ForEach(NoteDuration.allCases) { dur in
                Button { onPick(dur) } label: {
                    NoteDurationGlyph(duration: dur)
                        .frame(width: 40, height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(note.duration == dur
                                      ? Color.accentColor.opacity(0.22) : Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(note.duration == dur ? Color.accentColor : .clear,
                                        lineWidth: 2))
                        .foregroundColor(.primary)
                }
            }

            // Dot toggle (1.5× length, e.g. dotted quarter = 1.5 beats).
            Button(action: onToggleDot) {
                Text("\u{2022}")
                    .font(.system(size: 34, weight: .black))
                    .frame(width: 36, height: 46)
                    .foregroundColor(note.dotted ? .white : .accentColor)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(note.dotted ? Color.accentColor : Color.accentColor.opacity(0.12)))
            }

            Divider().frame(height: 30)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18))
                    .frame(width: 42, height: 46)
                    .foregroundColor(.red)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }

    private func accidentalButton(_ symbol: String, semitones: Int) -> some View {
        Button { onAccidental(semitones) } label: {
            Text(symbol)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 38, height: 46)
                .foregroundColor(.accentColor)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.12)))
        }
    }
}

// MARK: - Faint placement preview

private struct GhostPreview: View {
    let pitch: Pitch
    let pitchY: CGFloat
    let landingX: CGFloat
    let leftEdge: CGFloat
    let rightEdge: CGFloat
    let layout: StaffLayout
    let radius: CGFloat

    var body: some View {
        ZStack {
            // Full-width guide line at the chosen pitch — readable even where
            // the finger covers the staff.
            Path { p in
                p.move(to: CGPoint(x: leftEdge, y: pitchY))
                p.addLine(to: CGPoint(x: rightEdge, y: pitchY))
            }
            .stroke(Color.accentColor.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

            // Ledger lines at the landing spot for out-of-staff pitches.
            Canvas { ctx, _ in
                for ly in layout.ledgerLineYs(for: pitch) {
                    var path = Path()
                    path.move(to: CGPoint(x: landingX - radius - 6, y: ly))
                    path.addLine(to: CGPoint(x: landingX + radius + 6, y: ly))
                    ctx.stroke(path, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
                }
            }

            // Ghost notehead where the note will actually be placed.
            Ellipse()
                .fill(Color.accentColor.opacity(0.45))
                .overlay(Ellipse().stroke(Color.accentColor, lineWidth: 1.8))
                .frame(width: radius * 2.4, height: radius * 1.9)
                .rotationEffect(.degrees(-20))
                .position(x: landingX, y: pitchY)

            // Large pitch read-out, anchored at the landing spot (not the finger).
            Text("\(pitch.name)\(pitch.octave) · \(pitch.solfege)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .position(x: landingX, y: pitchY - 30)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - One note glyph

private struct NoteGlyph: View {
    let note: ScoreNote
    let x: CGFloat
    let layout: StaffLayout
    let radius: CGFloat
    let isSelected: Bool
    let isActive: Bool
    /// True when a beam (drawn separately) already provides this note's stem,
    /// so the glyph must not draw its own stem or flag.
    var beamed: Bool = false
    /// The score's key signature, so accidentals already implied by the key
    /// are left off and only deviations (incl. naturals) are drawn.
    var keySignature: Int = 0

    /// The accidental glyph to draw, reconciled against the key signature:
    /// nil when the note matches the key, else ♯ / ♭ / ♮ as appropriate.
    private var accidentalGlyph: String? {
        let keyAlt = KeySignature(count: keySignature).alteration(forLetter: note.pitch.letterIndex)
        let noteAlt = note.pitch.alteration
        guard noteAlt != keyAlt else { return nil }
        switch noteAlt {
        case 1:  return "\u{266F}"   // ♯
        case -1: return "\u{266D}"   // ♭
        default: return "\u{266E}"   // ♮ (cancels a key sharp/flat)
        }
    }

    var body: some View {
        let y = layout.y(for: note.pitch)

        let midY = layout.topLineY + 2 * layout.lineSpacing

        ZStack {
            if note.isRest {
                // Drawn directly — the Unicode rest glyphs (U+1D13x) aren't in
                // the system font and would render as empty boxes.
                Canvas { ctx, _ in
                    drawRest(ctx, x: x, midY: midY)
                }
            } else {
                // Ledger lines.
                Canvas { ctx, _ in
                    for ly in layout.ledgerLineYs(for: note.pitch) {
                        var path = Path()
                        path.move(to: CGPoint(x: x - radius - 6, y: ly))
                        path.addLine(to: CGPoint(x: x + radius + 6, y: ly))
                        ctx.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 1)
                    }
                }

                // Accidental, reconciled against the key signature (♯ / ♭ / ♮).
                if let acc = accidentalGlyph {
                    Text(acc)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(color)
                        // Flats render with their body low, so lift them a touch
                        // to center on the notehead the way the sharp already does.
                        .position(x: x - radius - 12,
                                  y: acc == "\u{266D}" ? y - 3 : y)
                }

                // Stem (skipped when a beam supplies it).
                let filled = note.duration != .whole
                if filled && !beamed {
                    Path { p in
                        let up = note.pitch.midi < 71 // below B4 -> stem up
                        if up {
                            p.move(to: CGPoint(x: x + radius - 1, y: y))
                            p.addLine(to: CGPoint(x: x + radius - 1, y: y - 42))
                        } else {
                            p.move(to: CGPoint(x: x - radius + 1, y: y))
                            p.addLine(to: CGPoint(x: x - radius + 1, y: y + 42))
                        }
                    }
                    .stroke(color, lineWidth: 1.6)
                }

                // Notehead.
                Ellipse()
                    .fill(noteheadFilled ? color : .clear)
                    .overlay(Ellipse().stroke(color, lineWidth: 1.8))
                    .frame(width: radius * 2.3, height: radius * 1.8)
                    .rotationEffect(.degrees(-20))
                    .position(x: x, y: y)

                // Flags for eighth / sixteenth (drawn as short strokes off
                // the stem tip — Unicode flag glyphs render inconsistently).
                // Beamed notes get a beam instead of a flag.
                if !beamed, note.duration == .eighth || note.duration == .sixteenth {
                    flagView(y: y)
                }
            }

            // Augmentation dot (1.5× length), to the right of the glyph. On a
            // line, it nudges up into the space above the way engravers do.
            if note.dotted {
                let steps = StaffLayout.diatonicSteps(from: note.pitch.midi,
                                                      prefersFlat: note.pitch.prefersFlat)
                let dotY = note.isRest
                    ? midY - 4
                    : (steps % 2 == 0 ? y - layout.lineSpacing / 2 : y)
                Circle()
                    .fill(color)
                    .frame(width: 4.4, height: 4.4)
                    .position(x: x + radius + 8, y: dotY)
            }

            // Selection ring / active highlight.
            if isSelected || isActive {
                Circle()
                    .stroke(isActive ? Color.orange : Color.blue,
                            lineWidth: isActive ? 3 : 2)
                    .frame(width: radius * 3.4, height: radius * 3.4)
                    .position(x: x, y: note.isRest ? midY : y)
            }
        }
    }

    /// Draw a rest shape for the note's duration, centered around the middle line.
    private func drawRest(_ ctx: GraphicsContext, x: CGFloat, midY: CGFloat) {
        let s = layout.lineSpacing
        switch note.duration {
        case .whole:
            // Solid bar hanging below the second line from the top.
            let lineY = layout.topLineY + s
            ctx.fill(Path(CGRect(x: x - 8, y: lineY - 6, width: 16, height: 6)),
                     with: .color(color))
        case .half:
            // Solid bar sitting on the middle line.
            ctx.fill(Path(CGRect(x: x - 8, y: midY - 6, width: 16, height: 6)),
                     with: .color(color))
        case .quarter:
            var p = Path()
            let top = midY - 16
            p.move(to: CGPoint(x: x - 4, y: top))
            p.addLine(to: CGPoint(x: x + 4, y: top + 8))
            p.addLine(to: CGPoint(x: x - 4, y: top + 16))
            p.addLine(to: CGPoint(x: x + 5, y: top + 26))
            p.addQuadCurve(to: CGPoint(x: x - 3, y: top + 30),
                           control: CGPoint(x: x + 7, y: top + 30))
            ctx.stroke(p, with: .color(color), lineWidth: 3)
        case .eighth, .sixteenth:
            var stroke = Path()
            let top = midY - 14
            stroke.move(to: CGPoint(x: x + 6, y: top))
            stroke.addLine(to: CGPoint(x: x - 5, y: top + 28))
            ctx.stroke(stroke, with: .color(color), lineWidth: 2)
            let flags = note.duration == .sixteenth ? 2 : 1
            for i in 0..<flags {
                let fy = top + CGFloat(i) * 9
                ctx.fill(Path(ellipseIn: CGRect(x: x + 1, y: fy, width: 6, height: 6)),
                         with: .color(color))
            }
        }
    }

    private var noteheadFilled: Bool {
        switch note.duration {
        case .whole, .half: return false
        default: return true
        }
    }

    private var color: Color {
        isActive ? .orange : (isSelected ? .blue : .black)
    }

    @ViewBuilder
    private func flagView(y: CGFloat) -> some View {
        let up = note.pitch.midi < 71
        let stemX = up ? x + radius - 1 : x - radius + 1
        let tip = up ? y - 42 : y + 42
        let flags = note.duration == .sixteenth ? 2 : 1
        Canvas { ctx, _ in
            for i in 0..<flags {
                let offset = CGFloat(i) * 8 * (up ? 1 : -1)
                var path = Path()
                let startY = tip + offset
                path.move(to: CGPoint(x: stemX, y: startY))
                path.addQuadCurve(
                    to: CGPoint(x: stemX + 10, y: startY + (up ? 14 : -14)),
                    control: CGPoint(x: stemX + 11, y: startY + (up ? 2 : -2)))
                ctx.stroke(path, with: .color(color), lineWidth: 2)
            }
        }
    }
}
