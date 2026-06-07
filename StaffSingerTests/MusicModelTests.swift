//
//  MusicModelTests.swift
//  StaffSingerTests
//
//  Unit tests for the music model: durations (incl. dotted), measure capacity
//  (catching the "5 beats in a 4/4 bar" / barline-crossing bugs), chord
//  grouping, key signatures, pitch spelling, and the staff-layout round trip.
//

import XCTest
@testable import StaffSinger

final class MusicModelTests: XCTestCase {

    // MARK: - Helpers

    /// Build a melody (one note per beat slot) from (duration, dotted) pairs,
    /// laying each note right after the previous one — exactly how the editor
    /// appends notes.
    private func melody(_ items: [(NoteDuration, Bool)],
                        beats: Int = 4, unit: Int = 4) -> Score {
        var score = Score()
        score.beatsPerMeasure = beats
        score.beatUnit = unit
        var cursor = 0.0
        for (dur, dotted) in items {
            let n = ScoreNote(pitch: .middleC, duration: dur,
                              beatOffset: cursor, dotted: dotted)
            score.notes.append(n)
            cursor += n.beats
        }
        return score
    }

    private func note(_ dur: NoteDuration, at beat: Double,
                      dotted: Bool = false, midi: Int = 60) -> ScoreNote {
        ScoreNote(pitch: Pitch(midi: midi), duration: dur,
                  beatOffset: beat, dotted: dotted)
    }

    // MARK: - Durations

    func testDurationBeats() {
        XCTAssertEqual(NoteDuration.whole.beats, 4.0)
        XCTAssertEqual(NoteDuration.half.beats, 2.0)
        XCTAssertEqual(NoteDuration.quarter.beats, 1.0)
        XCTAssertEqual(NoteDuration.eighth.beats, 0.5)
        XCTAssertEqual(NoteDuration.sixteenth.beats, 0.25)
    }

    func testDottedNoteBeats() {
        XCTAssertEqual(note(.quarter, at: 0, dotted: true).beats, 1.5, accuracy: 1e-9,
                       "점4분음표는 1.5박이어야 한다")
        XCTAssertEqual(note(.half, at: 0, dotted: true).beats, 3.0, accuracy: 1e-9)
        XCTAssertEqual(note(.eighth, at: 0, dotted: true).beats, 0.75, accuracy: 1e-9)
        XCTAssertEqual(note(.quarter, at: 0, dotted: false).beats, 1.0)
    }

    func testDurationLabel() {
        XCTAssertEqual(note(.quarter, at: 0).durationLabel, "4분음표")
        XCTAssertEqual(note(.quarter, at: 0, dotted: true).durationLabel, "점4분음표")
    }

    func testTotalBeats() {
        let score = melody([(.quarter, false), (.half, false), (.quarter, true)])
        // 1.0 + 2.0 + 1.5 = 4.5
        XCTAssertEqual(score.totalBeats, 4.5, accuracy: 1e-9)
    }

    // MARK: - Time signature

    func testQuarterBeatsPerMeasure() {
        var s = Score(); s.beatsPerMeasure = 4; s.beatUnit = 4
        XCTAssertEqual(s.measureCapacity, 4.0)
        s.beatsPerMeasure = 6; s.beatUnit = 8
        XCTAssertEqual(s.measureCapacity, 3.0, accuracy: 1e-9, "6/8 = 3 quarter beats")
        s.beatsPerMeasure = 3; s.beatUnit = 4
        XCTAssertEqual(s.measureCapacity, 3.0)
    }

    // MARK: - Measure validation (the bugs the user cares about)

    func testFullBarIsWellFormed() {
        let s = melody([(.quarter, false), (.quarter, false),
                        (.quarter, false), (.quarter, false)])
        XCTAssertEqual(s.measureLoads()[0], 4.0)
        XCTAssertTrue(s.overfilledMeasures.isEmpty)
        XCTAssertTrue(s.barlineCrossings.isEmpty)
        XCTAssertTrue(s.isWellFormed)
    }

    func testFiveQuartersSpanTwoBars() {
        // Five quarter notes are NOT five-in-one-bar: they tile into two bars.
        let s = melody(Array(repeating: (.quarter, false), count: 5))
        XCTAssertEqual(s.measureLoads()[0], 4.0)
        XCTAssertEqual(s.measureLoads()[1], 1.0)
        XCTAssertTrue(s.overfilledMeasures.isEmpty)
    }

    func testOverfilledMeasureDetected() {
        // Quarter, quarter, quarter at 0,1,2 then a HALF at beat 3 → the bar
        // holds 1+1+1+2 = 5 beats and the half spills past the barline.
        var s = Score(); s.beatsPerMeasure = 4; s.beatUnit = 4
        s.notes = [note(.quarter, at: 0), note(.quarter, at: 1),
                   note(.quarter, at: 2), note(.half, at: 3)]
        XCTAssertEqual(s.measureLoads()[0] ?? .nan, 5.0, accuracy: 1e-9, "한 마디에 5박")
        XCTAssertEqual(s.overfilledMeasures, [0])
        XCTAssertEqual(s.barlineCrossings, [3.0])
        XCTAssertFalse(s.isWellFormed)
    }

    func testDottedOverfill() {
        // 4/4 bar: half (2) + dotted half (3) starting at beat 2 → 5 beats,
        // and the dotted half crosses the barline.
        var s = Score(); s.beatsPerMeasure = 4; s.beatUnit = 4
        s.notes = [note(.half, at: 0), note(.half, at: 2, dotted: true)]
        XCTAssertEqual(s.measureLoads()[0] ?? .nan, 5.0, accuracy: 1e-9)
        XCTAssertEqual(s.overfilledMeasures, [0])
        XCTAssertEqual(s.barlineCrossings, [2.0])
    }

    func testChordCountsOnce() {
        // A chord (three notes sharing beat 0) plus three more quarters fills
        // the bar exactly — the chord must not be counted three times.
        var s = Score(); s.beatsPerMeasure = 4; s.beatUnit = 4
        s.notes = [note(.quarter, at: 0, midi: 60),
                   note(.quarter, at: 0, midi: 64),
                   note(.quarter, at: 0, midi: 67),
                   note(.quarter, at: 1), note(.quarter, at: 2), note(.quarter, at: 3)]
        XCTAssertEqual(s.measureLoads()[0] ?? .nan, 4.0, accuracy: 1e-9)
        XCTAssertTrue(s.isWellFormed)
    }

    func testThreeFourOverfill() {
        // 3/4 bar holds 3 beats; four quarters at 0,1,2 plus one more at 3 are
        // two bars, but a whole note (4) in a 3/4 bar overfills + crosses.
        var s = Score(); s.beatsPerMeasure = 3; s.beatUnit = 4
        s.notes = [note(.whole, at: 0)]
        XCTAssertEqual(s.measureLoads()[0], 4.0)
        XCTAssertEqual(s.overfilledMeasures, [0])
        XCTAssertEqual(s.barlineCrossings, [0.0])
    }

    func testEmptyScoreWellFormed() {
        XCTAssertTrue(Score().isWellFormed)
        XCTAssertTrue(Score().overfilledMeasures.isEmpty)
    }

    // MARK: - Chord grouping

    func testChordGroupsSortedAndGrouped() {
        var s = Score()
        s.notes = [note(.quarter, at: 2), note(.quarter, at: 0, midi: 60),
                   note(.quarter, at: 0, midi: 64)]
        let groups = s.chordGroups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].beat, 0.0)
        XCTAssertEqual(groups[0].notes.count, 2)
        XCTAssertEqual(groups[1].beat, 2.0)
    }

    // MARK: - Key signatures

    func testKeySignatureSharps() {
        // D major = 2 sharps: F♯, C♯ (letters F=3, C=0).
        let d = KeySignature(count: 2)
        XCTAssertEqual(d.alteration(forLetter: 3), 1, "F는 샵")
        XCTAssertEqual(d.alteration(forLetter: 0), 1, "C는 샵")
        XCTAssertEqual(d.alteration(forLetter: 4), 0, "G는 그대로")
    }

    func testKeySignatureFlats() {
        // B♭ major = 2 flats: B♭, E♭ (letters B=6, E=2).
        let bflat = KeySignature(count: -2)
        XCTAssertEqual(bflat.alteration(forLetter: 6), -1, "B는 플랫")
        XCTAssertEqual(bflat.alteration(forLetter: 2), -1, "E는 플랫")
        XCTAssertEqual(bflat.alteration(forLetter: 5), 0, "A는 그대로")
    }

    func testKeySignatureCMajor() {
        let c = KeySignature(count: 0)
        for letter in 0...6 {
            XCTAssertEqual(c.alteration(forLetter: letter), 0)
        }
    }

    func testKeySignatureShortLabel() {
        XCTAssertEqual(KeySignature(count: 0).shortLabel, "")
        XCTAssertEqual(KeySignature(count: 3).shortLabel, "♯3")
        XCTAssertEqual(KeySignature(count: -4).shortLabel, "♭4")
    }

    // MARK: - Pitch spelling

    func testPitchNames() {
        XCTAssertEqual(Pitch(midi: 60).name, "C")
        XCTAssertEqual(Pitch(midi: 61, prefersFlat: false).name, "C#")
        XCTAssertEqual(Pitch(midi: 61, prefersFlat: true).name, "Db")
        XCTAssertEqual(Pitch(midi: 70, prefersFlat: true).name, "Bb")
        XCTAssertEqual(Pitch(midi: 60).octave, 4, "Middle C = octave 4")
    }

    func testPitchLetterAndAlteration() {
        XCTAssertEqual(Pitch(midi: 61, prefersFlat: false).letterIndex, 0, "C# is letter C")
        XCTAssertEqual(Pitch(midi: 61, prefersFlat: false).alteration, 1)
        XCTAssertEqual(Pitch(midi: 61, prefersFlat: true).letterIndex, 1, "Db is letter D")
        XCTAssertEqual(Pitch(midi: 61, prefersFlat: true).alteration, -1)
        XCTAssertEqual(Pitch(midi: 60).alteration, 0)
    }

    func testMidiClamping() {
        XCTAssertEqual(Pitch(midi: -5).midi, 0)
        XCTAssertEqual(Pitch(midi: 999).midi, 127)
    }

    // MARK: - Staff layout

    func testStaffLayoutPitchRoundTrip() {
        let layout = StaffLayout(lineSpacing: 18, topLineY: 100)
        // Every natural pitch in a sensible range must map to a Y and back.
        for midi in stride(from: 60, through: 81, by: 1) {
            let p = Pitch(midi: midi)
            guard !p.isAccidental else { continue }   // only naturals land on lines
            let y = layout.y(for: p)
            let back = layout.pitch(forY: y)
            XCTAssertEqual(back.midi, midi, "Y \(y) should map back to MIDI \(midi)")
        }
    }

    func testTopLineIsF5() {
        let layout = StaffLayout(lineSpacing: 18, topLineY: 100)
        // The top staff line is F5 (MIDI 77) on a treble staff.
        XCTAssertEqual(layout.y(for: Pitch(midi: 77)), 100, accuracy: 0.001)
    }
}
