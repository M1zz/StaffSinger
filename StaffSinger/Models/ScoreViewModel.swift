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

    // Current editing tools.
    @Published var selectedDuration: NoteDuration = .quarter
    /// Whether newly placed notes get a dot (1.5× length).
    @Published var selectedDotted = false
    @Published var selectedNoteID: UUID? = nil
    /// When true, a new tap stacks onto the currently selected note's beat
    /// (i.e. builds a chord) instead of appending after it.
    @Published var chordMode = false

    /// The pitch currently under the finger while placing or moving a note.
    /// Drives the large position read-out at the bottom of the screen; nil
    /// when no drag is in progress.
    @Published var liveReadout: Pitch? = nil

    private let audio: AudioEngine

    init(audio: AudioEngine) {
        self.audio = audio
    }

    // MARK: - Derived

    /// Next free beat to append a note at (end of the score, snapped).
    var appendBeat: Double {
        score.totalBeats
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
            let note = ScoreNote(pitch: pitch, duration: selectedDuration,
                                 beatOffset: sel.beatOffset, dotted: selectedDotted)
            score.notes.append(note)
            selectedNoteID = note.id
            let stack = score.notes.filter { $0.beatOffset == sel.beatOffset && !$0.isRest }
            audio.auditionChord(stack.map { $0.pitch })
            return
        }

        // Melody mode: append, but keep the note inside the bar lines.
        let length = noteLength
        guard let beat = appendStartRespectingBars(length: length) else { return }
        let note = ScoreNote(pitch: pitch, duration: selectedDuration,
                             beatOffset: beat, dotted: selectedDotted)
        score.notes.append(note)
        selectedNoteID = note.id
        audio.audition(pitch)
    }

    /// Insert a rest of the current duration at the end (bar-aware).
    func addRest() {
        guard let beat = appendStartRespectingBars(length: noteLength) else { return }
        let note = ScoreNote(
            pitch: .middleC, duration: selectedDuration,
            beatOffset: beat, isRest: true, dotted: selectedDotted)
        score.notes.append(note)
        selectedNoteID = note.id
    }

    /// Length in beats of a note placed with the current tools.
    private var noteLength: Double {
        selectedDuration.beats * (selectedDotted ? 1.5 : 1.0)
    }

    /// Where an appended note/rest of `length` beats should start so it never
    /// straddles a barline and never spills past the two visible measures. If it
    /// would cross a barline, the rest of the current bar is padded with rests
    /// and the note starts on the next downbeat. Returns nil if it won't fit.
    private func appendStartRespectingBars(length: Double) -> Double? {
        let cap = score.measureCapacity
        guard cap > 0 else { return appendBeat }
        let limit = cap * 2
        let beat = appendBeat
        let nextBar = (floor((beat + 1e-6) / cap) + 1) * cap
        let crosses = beat + length > nextBar + 1e-6 && beat + 1e-6 < nextBar
        let start = crosses ? nextBar : beat
        guard start + length <= limit + 1e-6 else { return nil }   // won't fit in two bars
        if crosses {
            score.notes.append(contentsOf: rests(from: beat, length: nextBar - beat))
        }
        return start
    }

    // MARK: - Editing existing notes

    func changePitch(of id: UUID, semitones: Int) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
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
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
        score.notes[i].duration = duration
    }

    /// Toggle the dot (1.5× length) on a specific note.
    func toggleDot(of id: UUID) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
        score.notes[i].dotted.toggle()
    }

    /// Set the dot on a specific note (used by the toolbar's shared toggle).
    func setDotted(of id: UUID, _ value: Bool) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
        score.notes[i].dotted = value
    }

    /// Move an existing note to a new pitch and/or start beat (drag editing).
    func moveNote(_ id: UUID, toPitch pitch: Pitch, toBeat beat: Double) {
        guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
        score.notes[i].pitch = pitch
        score.notes[i].beatOffset = max(0, beat)
    }

    func deleteNote(_ id: UUID) {
        score.notes.removeAll { $0.id == id }
        if selectedNoteID == id { selectedNoteID = nil }
    }

    func deleteSelected() {
        if let id = selectedNoteID { deleteNote(id) }
    }

    func clearAll() {
        score.notes.removeAll()
        selectedNoteID = nil
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

    /// Apply the current key signature to a natural (white-key) pitch tapped on
    /// the staff, so placing on the "B" line in a flat key yields B♭, the "F"
    /// line in a sharp key yields F♯, and so on.
    func keyed(_ p: Pitch) -> Pitch {
        let alt = KeySignature(count: score.keySignature).alteration(forLetter: p.letterIndex)
        guard alt != 0 else { return p }
        return Pitch(midi: p.midi + alt, prefersFlat: alt < 0)
    }

    // MARK: - Auto-complete with rests

    /// Fill any silent gaps between notes — and pad the last measure up to a
    /// full bar (capped at two measures) — with rests, so an unfinished score
    /// becomes a complete, readable one before it plays.
    func fillRestsForPlayback() {
        let measureBeats = score.quarterBeatsPerMeasure
        guard measureBeats > 0 else { return }
        let groups = score.chordGroups
        guard !groups.isEmpty else { return }

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
        let target = min(2 * measureBeats,
                         (cursor / measureBeats).rounded(.up) * measureBeats)
        if target - cursor > 0.0001 {
            additions += rests(from: cursor, length: target - cursor)
        }

        score.notes.append(contentsOf: additions)
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
        fillRestsForPlayback()
        audio.play(score: score)
    }
    func stop() { audio.stop() }
}
