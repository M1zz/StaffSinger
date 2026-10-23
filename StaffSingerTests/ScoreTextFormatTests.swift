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

    // MARK: - Letter notation (every language but Korean)

    func testLetterNotationParses() {
        let notes = ScoreTextFormat.parse("C4:4 F#4:8 Bb3:2 R:4")
        XCTAssertEqual(notes.map(\.pitch.midi).prefix(3), [60, 66, 58])
        XCTAssertEqual(notes.map(\.duration), [.quarter, .eighth, .half, .quarter])
        XCTAssertTrue(notes[3].isRest)
        XCTAssertEqual(notes.map(\.beatOffset), [0, 1, 1.5, 3.5])
        XCTAssertTrue(notes[2].pitch.prefersFlat)
    }

    func testLetterNotationCarriesOctaveAndLength() {
        // D and E keep C5's octave and the eighth length.
        let notes = ScoreTextFormat.parse("C5:8 D E G4")
        XCTAssertEqual(notes.map(\.pitch.midi), [72, 74, 76, 67])
        XCTAssertTrue(notes.allSatisfy { $0.duration == .eighth })
    }

    func testLetterNotationDotAndTriplet() {
        let notes = ScoreTextFormat.parse("E4:4. G4:8t R:16.")
        XCTAssertTrue(notes[0].dotted)
        XCTAssertFalse(notes[0].triplet)
        XCTAssertTrue(notes[1].triplet)
        XCTAssertTrue(notes[2].isRest)
        XCTAssertTrue(notes[2].dotted)
        XCTAssertEqual(notes[2].duration, .sixteenth)
    }

    func testBothNotationsRoundTrip() {
        var score = Score()
        score.notes = [
            ScoreNote(pitch: Pitch(midi: 61, prefersFlat: true), duration: .quarter, beatOffset: 0),
            ScoreNote(pitch: Pitch(midi: 67), duration: .eighth, beatOffset: 1, triplet: true),
            ScoreNote(pitch: .middleC, duration: .eighth, beatOffset: 1 + 1.0 / 3, isRest: true),
            ScoreNote(pitch: Pitch(midi: 79), duration: .half, beatOffset: 1 + 1.0 / 3 + 0.5, dotted: true),
        ]
        for korean in [true, false] {
            let parsed = ScoreTextFormat.parse(ScoreTextFormat.serialize(score, korean: korean))
            XCTAssertEqual(parsed.count, score.notes.count, "korean: \(korean)")
            for (a, b) in zip(parsed, score.notes) {
                XCTAssertEqual(a.pitch.midi, b.pitch.midi)
                XCTAssertEqual(a.isRest, b.isRest)
                XCTAssertEqual(a.duration, b.duration)
                XCTAssertEqual(a.dotted, b.dotted)
                XCTAssertEqual(a.triplet, b.triplet)
                XCTAssertEqual(a.beatOffset, b.beatOffset, accuracy: 1e-9)
            }
        }
    }

    func testLetterSerializeLooksLikeTheRule() {
        var score = Score()
        score.notes = [ScoreNote(pitch: Pitch(midi: 60), duration: .quarter, beatOffset: 0),
                       ScoreNote(pitch: .middleC, duration: .eighth, beatOffset: 1, isRest: true)]
        XCTAssertEqual(ScoreTextFormat.serialize(score, korean: false), "C4:4 R:8")
    }

    func testRuleTextHasNoKoreanOutsideKorean() {
        // The letter rule is what every non-Korean language shows; its example
        // must parse with the same parser.
        let example = "C4:4 D4:4 E4:8 F4:8 G4:2"
        XCTAssertEqual(ScoreTextFormat.parse(example).map(\.pitch.midi), [60, 62, 64, 65, 67])
    }
}

/// Spoken solfege in English ("high sol", "fa sharp") — what every language
/// but Korean listens for.
final class SpokenSolfegeEnglishTests: XCTestCase {

    private func notes(_ words: [String]) -> [ScoreNote] {
        let events = words.enumerated().map { SpokenEvent(word: $1, time: Double($0) * 0.5) }
        // 120 BPM: one word per beat.
        return SpokenSolfege.notes(from: events, tempo: 120, grid: .quarter, baseOctave: 4,
                                   autoOctave: true, measureBeats: 4, capacityBeats: 8)
    }

    func testEnglishSyllables() {
        XCTAssertEqual(notes(["do", "re", "mi", "fa"]).map(\.pitch.midi), [60, 62, 64, 65])
        XCTAssertEqual(notes(["Sol", "La", "Ti", "Do"]).map(\.pitch.midi), [67, 69, 71, 72])
    }

    func testEnglishRest() {
        let n = notes(["do", "rest", "mi"])
        XCTAssertEqual(n.map(\.isRest), [false, true, false])
    }

    func testStandaloneHighLiftsNextNote() {
        // Without "high", sol after do falls to G3 (nearest); with it, G4.
        XCTAssertEqual(notes(["do", "sol"]).map(\.pitch.midi), [60, 55])
        // "high" is spoken as its own word and must not take a beat of its own.
        let events = [SpokenEvent(word: "do", time: 0), SpokenEvent(word: "high", time: 0.4),
                      SpokenEvent(word: "sol", time: 0.5)]
        let n = SpokenSolfege.notes(from: events, tempo: 120, grid: .quarter, baseOctave: 4,
                                    autoOctave: true, measureBeats: 4, capacityBeats: 8)
        XCTAssertEqual(n.map(\.pitch.midi), [60, 67])
    }

    func testStandaloneSharpRaisesPreviousNote() {
        let events = [SpokenEvent(word: "fa", time: 0), SpokenEvent(word: "sharp", time: 0.2),
                      SpokenEvent(word: "sol", time: 0.5)]
        let n = SpokenSolfege.notes(from: events, tempo: 120, grid: .quarter, baseOctave: 4,
                                    autoOctave: true, measureBeats: 4, capacityBeats: 8)
        XCTAssertEqual(n.map(\.pitch.midi), [66, 67])
    }

    func testOrdinaryWordsAreIgnored() {
        XCTAssertNil(SpokenSolfege.token(for: "hello"))
        XCTAssertNil(SpokenSolfege.token(for: "high"))
        XCTAssertNotNil(SpokenSolfege.modifier(for: "High"))
    }
}
