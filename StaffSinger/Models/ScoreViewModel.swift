//
//  ScoreViewModel.swift
//  StaffSinger
//
//  Owns the editable Score and all mutation logic (placing, moving,
//  deleting notes, building chords, changing time/tempo). The views stay
//  dumb; everything that changes the document goes through here.
//

import Foundation
import Combine

@MainActor
final class ScoreViewModel: ObservableObject {

    @Published var score = Score()

    // Current editing tools. The duration & dot persist across launches so the
    // editor reopens with whatever the user set last, instead of resetting to a
    // quarter note every time.
    @Published var selectedDuration: NoteDuration = ScoreViewModel.savedDuration {
        didSet { UserDefaults.standard.set(selectedDuration.rawValue, forKey: Self.durationKey) }
    }
    /// Whether newly placed notes get a dot (1.5× length).
    @Published var selectedDotted = UserDefaults.standard.bool(forKey: ScoreViewModel.dottedKey) {
        didSet { UserDefaults.standard.set(selectedDotted, forKey: Self.dottedKey) }
    }
    @Published var selectedNoteID: UUID? = nil
    /// When true, a new tap stacks onto the currently selected note's beat
    /// (i.e. builds a chord) instead of appending after it.
    @Published var chordMode = false
    /// When true, pressing the staff drops a rest of the current duration
    /// instead of a pitched note.
    @Published var restMode = false
    /// When true, new notes/rests are triplet-valued (셋잇단음표) — three fit
    /// in the space of two.
    @Published var tripletMode = false

    // MARK: - Persisted tool defaults

    private static let durationKey = "editor.selectedDuration"
    private static let dottedKey = "editor.selectedDotted"

    /// The last duration the user chose, or a quarter note on first launch.
    private static var savedDuration: NoteDuration {
        guard let raw = UserDefaults.standard.string(forKey: durationKey),
              let d = NoteDuration(rawValue: raw) else { return .quarter }
        return d
    }

    /// The voice / layer new notes are written into. Each layer builds up its
    /// own line independently in time; layers overlap to form harmony.
    @Published var activeLayer = 0
    /// How many voices the editor exposes.
    static let layerCount = 3

    /// The pitch currently under the finger while placing or moving a note.
    /// Drives the large position read-out at the bottom of the screen; nil
    /// when no drag is in progress.
    @Published var liveReadout: Pitch? = nil

    /// The note the next piano key (or hummed pitch) rewrites. Set when the
    /// user picks a note to fix; it moves on to the next note after each
    /// rewrite, so a whole line can be corrected by simply playing it again.
    /// Nil means keys append, as usual.
    @Published private(set) var cursorID: UUID? = nil

    /// Notes the photo reader wasn't sure about. Editing a note — or saying
    /// it's right — takes it off the list.
    @Published private(set) var unsureIDs: Set<UUID> = []

    private let audio: AudioEngine

    // MARK: - Undo

    /// One restorable state of the notes. Score settings (tempo, key…) have
    /// their own controls and are left out — undo is for note edits.
    private struct Snapshot { let notes: [ScoreNote]; let unsure: Set<UUID> }
    private var history: [Snapshot] = []
    @Published private(set) var canUndo = false

    /// Remember the notes as they are (or as they were, if given), before an
    /// edit changes them.
    func checkpoint(_ notes: [ScoreNote]? = nil) {
        history.append(Snapshot(notes: notes ?? score.notes, unsure: unsureIDs))
        if history.count > 100 { history.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard let last = history.popLast() else { return }
        score.notes = last.notes
        unsureIDs = last.unsure
        let ids = Set(score.notes.map(\.id))
        if let id = selectedNoteID, !ids.contains(id) { selectedNoteID = nil }
        if let id = cursorID, !ids.contains(id) { cursorID = nil }
        canUndo = !history.isEmpty
    }

    init(audio: AudioEngine) {
        self.audio = audio
    }

    // MARK: - Derived

    /// Next free beat to append in the active layer (end of that voice).
    var appendBeat: Double { appendBeat(forLayer: activeLayer) }

    /// End beat of a specific voice (where its next note would go).
    func appendBeat(forLayer layer: Int) -> Double {
        let ends: [Double] = score.notes
            .filter { $0.layer == layer }
            .map { $0.beatOffset + $0.beats }
        return ends.max() ?? 0
    }

    var selectedNote: ScoreNote? {
        guard let id = selectedNoteID else { return nil }
        return score.notes.first { $0.id == id }
    }

    // MARK: - Placing notes

    /// Add a note at the given pitch. Behavior depends on `chordMode`:
    /// - off: append at the end of the score (melody building)
    /// - on:  stack onto the selected note's beat (chord building)
    func addNote(pitch: Pitch) {
        // Chord mode: stack onto the selected note's beat — no reflow needed.
        if chordMode, let sel = selectedNote {
            checkpoint()
            let note = ScoreNote(pitch: pitch, duration: selectedDuration,
                                 beatOffset: sel.beatOffset, dotted: selectedDotted,
                                 layer: activeLayer, triplet: sel.triplet)
            score.notes.append(note)
            selectedNoteID = note.id
            let stack = score.notes.filter { $0.beatOffset == sel.beatOffset && !$0.isRest }
            audio.auditionChord(stack.map { $0.pitch })
            return
        }

        // A note picked for fixing gets rewritten instead of appended to.
        if cursorID != nil {
            rewriteCursor(with: pitch)
            return
        }

        // Melody mode: append into the active voice, inside the bar lines.
        let before = score.notes
        guard let beat = appendStartRespectingBars(length: noteLength, layer: activeLayer) else { return }
        checkpoint(before)
        let note = ScoreNote(pitch: pitch, duration: selectedDuration,
                             beatOffset: beat, dotted: selectedDotted,
                             layer: activeLayer, triplet: tripletMode)
        score.notes.append(note)
        selectedNoteID = note.id
        audio.audition(pitch)
    }

    /// Insert a rest at the end of the active voice. Defaults to the current
    /// tool duration, but a specific value can be passed (the rest-length
    /// buttons use this so any rest value can be dropped in one tap).
    /// Returns false when the rest wouldn't fit in the two visible measures, so
    /// callers can skip the "it worked" feedback instead of buzzing at nothing.
    @discardableResult
    func addRest(duration: NoteDuration? = nil) -> Bool {
        let dur = duration ?? selectedDuration
        let length = dur.beats * (selectedDotted ? 1.5 : 1.0) * (tripletMode ? 2.0 / 3.0 : 1.0)
        let before = score.notes
        guard let beat = appendStartRespectingBars(length: length, layer: activeLayer) else { return false }
        checkpoint(before)
        cursorID = nil
        let note = ScoreNote(
            pitch: .middleC, duration: dur,
            beatOffset: beat, isRest: true, dotted: selectedDotted,
            layer: activeLayer, triplet: tripletMode)
        score.notes.append(note)
        selectedNoteID = note.id
        return true
    }

    /// Length in beats of a note placed with the current tools.
    private var noteLength: Double {
        selectedDuration.beats * (selectedDotted ? 1.5 : 1.0) * (tripletMode ? 2.0 / 3.0 : 1.0)
    }

    /// Where an appended note/rest of `length` beats should start so it never
    /// straddles a barline and never spills past the two visible measures. If it
    /// would cross a barline, the rest of the current bar is padded with rests
    /// and the note starts on the next downbeat. Returns nil if it won't fit.
    private func appendStartRespectingBars(length: Double, layer: Int) -> Double? {
        let cap = score.measureCapacity
        guard cap > 0 else { return appendBeat(forLayer: layer) }
        let limit = cap * 2
        let beat = appendBeat(forLayer: layer)
        let nextBar = (floor((beat + 1e-6) / cap) + 1) * cap
        let crosses = beat + length > nextBar + 1e-6 && beat + 1e-6 < nextBar
        let start = crosses ? nextBar : beat
        guard start + length <= limit + 1e-6 else { return nil }   // won't fit in two bars
        if crosses {
            var gap = rests(from: beat, length: nextBar - beat)
            for i in gap.indices { gap[i].layer = layer }
            score.notes.append(contentsOf: gap)
        }
        return start
    }

    // MARK: - Editing existing notes

    func changePitch(of id: UUID, semitones: Int) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        unsureIDs.remove(id)
        let old = score.notes[i].pitch
        var newPitch = Pitch(midi: old.midi + semitones)
        // Spell black keys by the direction of the nudge: a half-step up reads
        // as a sharp, a half-step down as a flat. Octave jumps keep the note's
        // existing spelling so they don't silently flip ♯⇄♭.
        if newPitch.isAccidental {
            newPitch.prefersFlat = (abs(semitones) % 12 == 0)
                ? old.prefersFlat
                : semitones < 0
        }
        score.notes[i].pitch = newPitch
        if !score.notes[i].isRest { audio.audition(newPitch) }
    }

    func changeDuration(of id: UUID, to duration: NoteDuration) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }),
              score.notes[i].duration != duration else { return }
        checkpoint()
        unsureIDs.remove(id)
        score.notes[i].duration = duration
    }

    /// Toggle the dot (1.5× length) on a specific note.
    func toggleDot(of id: UUID) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        score.notes[i].dotted.toggle()
    }

    /// Set the dot on a specific note (used by the toolbar's shared toggle).
    func setDotted(of id: UUID, _ value: Bool) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }),
              score.notes[i].dotted != value else { return }
        checkpoint()
        score.notes[i].dotted = value
    }

    /// Move an existing note to a new pitch and/or start beat (drag editing).
    /// Called on every step of a drag, so the caller takes one `checkpoint()`
    /// when the drag begins rather than one per step.
    func moveNote(_ id: UUID, toPitch pitch: Pitch, toBeat beat: Double) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
        unsureIDs.remove(id)
        score.notes[i].pitch = pitch
        score.notes[i].beatOffset = max(0, beat)
    }

    func deleteNote(_ id: UUID) {
        checkpoint()
        score.notes.removeAll { $0.id == id }
        unsureIDs.remove(id)
        if selectedNoteID == id { selectedNoteID = nil }
        if cursorID == id { cursorID = nil }
    }

    func deleteSelected() {
        if let id = selectedNoteID { deleteNote(id) }
    }

    /// The last event in a voice — whatever ends latest in time.
    private func lastEvent(inLayer layer: Int) -> ScoreNote? {
        score.notes
            .filter { $0.layer == layer }
            .max { ($0.beatOffset + $0.beats) < ($1.beatOffset + $1.beats) }
    }

    /// True when there is something for `deleteLast()` to take off.
    var canDeleteLast: Bool { lastEvent(inLayer: activeLayer) != nil }

    /// Backspace for the piano: drop the most recent event in the active voice.
    ///
    /// Exactly one event comes off per press, never a run of them — placing a
    /// note can pad the bar with rests, and silently eating those too would
    /// make one tap delete two things the user can see. Pressing again removes
    /// the next one, the way backspace works everywhere else.
    @discardableResult
    func deleteLast() -> Bool {
        guard let last = lastEvent(inLayer: activeLayer) else { return false }
        deleteNote(last.id)
        return true
    }

    func clearAll() {
        checkpoint()
        replaceNotes([])
    }

    /// Swap in a whole new set of notes (imports, clearing). Selection, the
    /// fixing cursor and the unsure marks all belong to the old notes.
    private func replaceNotes(_ notes: [ScoreNote], unsure: Set<UUID> = []) {
        score.notes = notes
        unsureIDs = unsure
        selectedNoteID = nil
        cursorID = nil
    }

    // MARK: - Fixing notes (cursor, hummed pitch, review)

    /// The user picked a note to look at or fix: select it, and point the
    /// keys at it.
    func pick(_ id: UUID) {
        selectedNoteID = id
        cursorID = id
    }

    /// Keys go back to appending.
    func dropCursor() { cursorID = nil }

    /// Rewrite the cursor note with `pitch` (it becomes a sounding note even
    /// if it was a rest), then step the cursor to the next note in its voice.
    private func rewriteCursor(with pitch: Pitch) {
        guard let id = cursorID,
              let i = score.notes.firstIndex(where: { $0.id == id }) else { cursorID = nil; return }
        checkpoint()
        score.notes[i].pitch = pitch
        score.notes[i].isRest = false
        unsureIDs.remove(id)
        audio.audition(pitch)
        let next = nextNote(after: score.notes[i])
        selectedNoteID = next?.id ?? id
        cursorID = next?.id
    }

    /// The next sounding note after `note` in the same voice, if any.
    private func nextNote(after note: ScoreNote) -> ScoreNote? {
        score.notes
            .filter { $0.layer == note.layer && !$0.isRest && $0.beatOffset > note.beatOffset + 1e-6 }
            .min { ($0.beatOffset, -$0.pitch.midi) < ($1.beatOffset, -$1.pitch.midi) }
    }

    /// A sung pitch, written the way the score would spell it: the voice
    /// decides the note name, the score decides the octave — the octave
    /// closest to the note being fixed (or to the end of the line when
    /// appending), so a low voice can fix a high note.
    func addSung(midi: Int) {
        let target = cursorID.flatMap { id in score.notes.first { $0.id == id } }
            ?? lastEvent(inLayer: activeLayer).flatMap { $0.isRest ? nil : $0 }
        let around = target?.pitch.midi ?? score.clef.middleLineMidi
        let pc = ((midi % 12) + 12) % 12
        var placed = around - (((around - pc) % 12) + 12) % 12   // same name, at or below
        if around - placed > 6 { placed += 12 }
        addNote(pitch: Pitch(midi: placed, prefersFlat: score.keySignature < 0))
    }

    /// Unsure notes in reading order.
    private var unsureInOrder: [ScoreNote] {
        score.notes
            .filter { unsureIDs.contains($0.id) }
            .sorted { ($0.beatOffset, $0.layer) < ($1.beatOffset, $1.layer) }
    }

    /// Show the next unsure note: pick it and let it sound.
    func reviewNext() {
        guard let note = unsureInOrder.first(where: { $0.id != cursorID }) ?? unsureInOrder.first
        else { return }
        pick(note.id)
        if !note.isRest { audio.audition(note.pitch) }
    }

    /// "It's right": take the cursor note off the unsure list and move on.
    func confirmCursor() {
        guard let id = cursorID else { return }
        checkpoint()
        unsureIDs.remove(id)
        if unsureIDs.isEmpty { cursorID = nil } else { reviewNext() }
    }

    /// While playing: stop, and pick the note that was sounding (or `id`).
    func stopAndPick(_ id: UUID? = nil) {
        let beat = audio.currentBeat
        audio.stop()
        if let id { pick(id); return }
        guard let beat else { return }
        // The latest note that had started by then; a rest only if nothing sounded.
        let started = score.notes.filter { $0.beatOffset <= beat + 1e-6 }
        let latest: (ScoreNote, ScoreNote) -> Bool = {
            ($0.isRest ? 0 : 1, $0.beatOffset, $0.pitch.midi) < ($1.isRest ? 0 : 1, $1.beatOffset, $1.pitch.midi)
        }
        if let note = started.max(by: latest) { pick(note.id) }
    }

    // MARK: - Paste from text

    /// Replace the score with notes parsed from pasted text (the AI-readable
    /// format in `ScoreTextFormat`). Returns the imported notes so the caller
    /// can report how many landed; an empty result means nothing parsed and the
    /// existing score is left untouched.
    @discardableResult
    func importFromText(_ text: String) -> [ScoreNote] {
        let notes = ScoreTextFormat.parse(text)
        guard !notes.isEmpty else { return [] }
        checkpoint()
        replaceNotes(notes)
        return notes
    }

    /// Replace the score with a ready-made list of notes (voice dictation).
    /// Mirrors `importFromText` so every bulk import lands the same way.
    /// `unsure` marks the notes the source wasn't confident about (the photo
    /// reader), so the review can walk the user through just those.
    func importNotes(_ notes: [ScoreNote], unsure: Set<UUID> = []) {
        guard !notes.isEmpty else { return }
        checkpoint()
        replaceNotes(notes, unsure: unsure)
    }

    /// The current score rendered back into the text format — handy to copy out
    /// as a worked example for the AI.
    func exportToText() -> String {
        ScoreTextFormat.serialize(score)
    }

    // MARK: - Score settings

    func setTempo(_ bpm: Double) {
        score.tempo = max(20, min(240, bpm))
    }

    func setTimeSignature(beats: Int, unit: Int) {
        score.beatsPerMeasure = beats
        score.beatUnit = unit
    }

    func setKeySignature(_ count: Int) {
        score.keySignature = max(-7, min(7, count))
    }

    func setClef(_ clef: Clef) {
        score.clef = clef
    }

    /// Apply the current key signature to a natural (white-key) pitch tapped on
    /// the staff, so placing on the "B" line in a flat key yields B♭, the "F"
    /// line in a sharp key yields F♯, and so on.
    func keyed(_ p: Pitch) -> Pitch {
        let alt = KeySignature(count: score.keySignature).alteration(forLetter: p.letterIndex)
        guard alt != 0 else { return p }
        return Pitch(midi: p.midi + alt, prefersFlat: alt < 0)
    }

    // MARK: - Auto-complete with rests

    /// A copy of the score prepared for playback: any silent gap *between* notes
    /// is filled with rests so the timing reads right, and a trailing partial
    /// measure is padded up to its bar line (≤ two measures).
    ///
    /// Crucially this is **non-destructive** — it never touches the editable
    /// `score`, so pressing play never adds rests to what the user sees. When
    /// every measure is already correctly filled (e.g. 8 8 4 4 4 = a full 4/4
    /// bar) there are no gaps and nothing to pad, so the score is returned as-is.
    func scoreForPlayback() -> Score {
        var result = score
        let measureBeats = result.quarterBeatsPerMeasure
        guard measureBeats > 0 else { return result }
        let groups = result.chordGroups
        guard !groups.isEmpty else { return result }

        var additions: [ScoreNote] = []
        var cursor = 0.0
        for g in groups {
            if g.beat - cursor > 0.0001 {
                additions += rests(from: cursor, length: g.beat - cursor)
            }
            let dur = g.notes.map { $0.beats }.max() ?? 1.0
            cursor = max(cursor, g.beat + dur)
        }

        // Pad the trailing partial measure up to a bar line (≤ two measures).
        // A measure that already lands exactly on a bar line adds nothing.
        let target = min(2 * measureBeats,
                         (cursor / measureBeats).rounded(.up) * measureBeats)
        if target - cursor > 0.0001 {
            additions += rests(from: cursor, length: target - cursor)
        }

        result.notes.append(contentsOf: additions)
        return result
    }

    /// Greedily express a span of empty beats as the fewest standard rests.
    private func rests(from start: Double, length: Double) -> [ScoreNote] {
        let durations: [NoteDuration] = [.whole, .half, .quarter, .eighth, .sixteenth]
        var result: [ScoreNote] = []
        var pos = start
        var remaining = length
        while remaining > 0.0001 {
            guard let d = durations.first(where: { $0.beats <= remaining + 0.0001 }) else { break }
            result.append(ScoreNote(pitch: .middleC, duration: d,
                                    beatOffset: pos, isRest: true))
            pos += d.beats
            remaining -= d.beats
        }
        return result
    }

    // MARK: - Playback proxies

    func play() {
        audio.play(score: scoreForPlayback())
    }
    func stop() { audio.stop() }
}
