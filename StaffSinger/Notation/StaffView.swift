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
        let clefSpace: CGFloat = 58
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

            ZStack(alignment: .topLeading) {
                staffLines(layout: layout, m: m)
                barlines(layout: layout, m: m)
                clef(layout: layout, m: m)
                tapCatcher(layout: layout)        // empty-staff taps (add) — below notes
                noteLayer(layout: layout, m: m)   // existing notes (move/delete) — on top
                ghostLayer(layout: layout, m: m)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: staffSpace)
        }
        .background(Color(red: 0.99, green: 0.98, blue: 0.95))
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

    // MARK: - Notes (only those within the two visible measures)

    /// The start beat of the group currently sounding, for the play highlight.
    private var activeBeat: Double? {
        guard let idx = audio.currentGroupIndex else { return nil }
        let groups = vm.score.chordGroups
        return idx < groups.count ? groups[idx].beat : nil
    }

    private func noteLayer(layout: StaffLayout, m: Metrics) -> some View {
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
                        isSelected: vm.selectedNoteID == note.id, isActive: isActive
                    )
                    .allowsHitTesting(false)

                    // Compact hit target: tap = select, long-press = delete,
                    // drag = move (pitch by Y, beat by X).
                    Color.clear
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.selectedNoteID = note.id
                            if !note.isRest { audio.audition(note.pitch) }
                        }
                        .onLongPressGesture(minimumDuration: 0.4) {
                            deleteHaptic.impactOccurred()
                            vm.deleteNote(note.id)
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
                let newPitch = layout.pitch(forY: value.location.y)

                let snap = 0.5
                let raw = Double((value.location.x - m.musicStartX) / m.beatWidth)
                let beat = min(max(0, (raw / snap).rounded() * snap),
                               Double(m.beatLimit) - 0.25)

                if !note.isRest, movingPitch != newPitch {
                    movingPitch = newPitch
                    audio.previewNote(newPitch)
                    haptics.selectionChanged()
                    haptics.prepare()
                }
                vm.moveNote(note.id, toPitch: newPitch, toBeat: beat)
            }
            .onEnded { _ in
                audio.endPreview()
                movingPitch = nil
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
                        let pitch = layout.pitch(forY: value.location.y)
                        if previewPitch != pitch {
                            if previewPitch == nil { haptics.prepare() }
                            previewPitch = pitch
                            audio.previewNote(pitch)        // sound on change
                            haptics.selectionChanged()      // haptic on change
                            haptics.prepare()
                        }
                    }
                    .onEnded { value in
                        let committed = previewPitch ?? layout.pitch(forY: value.location.y)
                        audio.endPreview()
                        previewPitch = nil
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
            Text("\(pitch.nameSharp)\(pitch.octave) · \(pitch.solfege)")
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

                // Accidental.
                if note.pitch.isAccidental {
                    Text("\u{266F}") // sharp
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(color)
                        .position(x: x - radius - 12, y: y)
                }

                // Stem.
                let filled = note.duration != .whole
                if filled {
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
                if note.duration == .eighth || note.duration == .sixteenth {
                    flagView(y: y)
                }
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
