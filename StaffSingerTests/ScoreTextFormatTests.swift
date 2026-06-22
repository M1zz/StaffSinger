//
//  ScoreTextFormatTests.swift
//  StaffSingerTests
//
//  Tests for the pasteable text notation: parsing tokens into notes (octave,
//  solfege, accidentals, durations, dots, triplets, rests, carry-over) and the
//  serialize → parse round trip.
//

import XCTest
@testable import StaffSinger

final class ScoreTextFormatTests: XCTestCase {

    // MARK: - Parse

    func testParsesOctaveSolfegeAndDuration() {
        // 4옥도8분음 = C4, eighth note (middle C, half a beat).
        let notes = ScoreTextFormat.parse("4옥도8분음")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].pitch.midi, 60)       // C4
        XCTAssertEqual(notes[0].duration, .eighth)
        XCTAssertEqual(notes[0].beats, 0.5, accuracy: 1e-9)
        XCTAssertFalse(notes[0].isRest)
    }

    func testLaysNotesSequentiallyFromBeatZero() {
        let notes = ScoreTextFormat.parse("4옥도4분음 4옥레4분음 4옥미2분음")
        XCTAssertEqual(notes.map(\.beatOffset), [0.0, 1.0, 2.0])
        XCTAssertEqual(notes.map(\.pitch.midi), [60, 62, 64])   // C4 D4 E4
    }

    func testSharpAndFlatAccidentals() {
        let sharp = ScoreTextFormat.parse("4옥파#4분음")
        XCTAssertEqual(sharp.first?.pitch.midi, 66)             // F#4
        XCTAssertEqual(sharp.first?.pitch.prefersFlat, false)

        let flat = ScoreTextFormat.parse("4옥시b4분음")
        XCTAssertEqual(flat.first?.pitch.midi, 70)              // B♭4
        XCTAssertEqual(flat.first?.pitch.prefersFlat, true)
    }

    func testOctaveAndDurationCarryOver() {
        // Second token omits the octave; third omits the duration.
        let notes = ScoreTextFormat.parse("5옥도4분음 레 미8분음")
        XCTAssertEqual(notes.map(\.pitch.midi), [72, 74, 76])   // all octave 5
        XCTAssertEqual(notes.map(\.duration), [.quarter, .quarter, .eighth])
    }

    func testDottedAndTriplet() throws {
        let dotted = ScoreTextFormat.parse("점4옥도4분음")
        let d = try XCTUnwrap(dotted.first)
        XCTAssertTrue(d.dotted)
        XCTAssertEqual(d.beats, 1.5, accuracy: 1e-9)

        let triplet = ScoreTextFormat.parse("셋잇단4옥도8분음")
        let t = try XCTUnwrap(triplet.first)
        XCTAssertTrue(t.triplet)
        XCTAssertEqual(t.beats, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testRestParsesAndOccupiesTime() {
        let notes = ScoreTextFormat.parse("4옥도4분음 4분쉼 4옥미4분음")
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes[1].isRest)
        XCTAssertEqual(notes[1].beats, 1.0, accuracy: 1e-9)
        XCTAssertEqual(notes[2].beatOffset, 2.0, accuracy: 1e-9)  // pushed past the rest
    }

    func testWholeNoteAndEnglishLetters() {
        let whole = ScoreTextFormat.parse("4옥도온음")
        XCTAssertEqual(whole.first?.duration, .whole)

        let english = ScoreTextFormat.parse("4옥G4분음")
        XCTAssertEqual(english.first?.pitch.midi, 67)            // G4
    }

    func testGarbageTokensSkippedNotFatal() {
        let notes = ScoreTextFormat.parse("안녕 4옥도4분음 ??? 4옥레4분음")
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.map(\.pitch.midi), [60, 62])
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertTrue(ScoreTextFormat.parse("   \n  ").isEmpty)
    }

    // MARK: - Round trip

    func testSerializeThenParseRoundTrip() {
        var score = Score()
        score.notes = [
            ScoreNote(pitch: Pitch(midi: 60), duration: .quarter, beatOffset: 0),
            ScoreNote(pitch: Pitch(midi: 66), duration: .eighth, beatOffset: 1),   // F#4
            ScoreNote(pitch: .middleC, duration: .quarter, beatOffset: 1.5, isRest: true),
            ScoreNote(pitch: Pitch(midi: 72), duration: .half, beatOffset: 2.5, dotted: true),
        ]
        let text = ScoreTextFormat.serialize(score)
        let parsed = ScoreTextFormat.parse(text)

        XCTAssertEqual(parsed.count, score.notes.count)
        for (a, b) in zip(parsed, score.notes) {
            XCTAssertEqual(a.pitch.midi, b.pitch.midi)
            XCTAssertEqual(a.duration, b.duration)
            XCTAssertEqual(a.isRest, b.isRest)
            XCTAssertEqual(a.dotted, b.dotted)
            XCTAssertEqual(a.beatOffset, b.beatOffset, accuracy: 1e-9)
        }
    }
}
