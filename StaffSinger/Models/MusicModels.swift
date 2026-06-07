//
//  MusicModels.swift
//  StaffSinger
//
//  Core music data model. Everything is expressed in terms that map
//  cleanly to (a) where a note sits on the staff and (b) how the audio
//  engine should schedule it in time.
//

import Foundation

// MARK: - Pitch

/// A pitch expressed as a MIDI note number (0...127). Middle C = 60.
/// We keep the MIDI number as the single source of truth because both
/// the staff layout and the audio engine derive everything from it.
struct Pitch: Equatable, Hashable, Codable {
    var midi: Int
    /// Spelling hint for black keys: when true a black key is written as a flat
    /// of the letter above (D♭) rather than a sharp of the letter below (C♯).
    /// Ignored for white keys. Drives both the drawn accidental and where the
    /// notehead sits on the staff.
    var prefersFlat: Bool = false

    init(midi: Int, prefersFlat: Bool = false) {
        self.midi = max(0, min(127, midi))
        self.prefersFlat = prefersFlat
    }

    private var pitchClass: Int { ((midi % 12) + 12) % 12 }

    /// Letter name without octave, using sharps. e.g. 60 -> "C", 61 -> "C#"
    var nameSharp: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[pitchClass]
    }

    /// Letter name using flats. e.g. 61 -> "Db", 70 -> "Bb"
    var nameFlat: String {
        let names = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
        return names[pitchClass]
    }

    /// Letter name honoring the chosen spelling.
    var name: String { prefersFlat ? nameFlat : nameSharp }

    /// Solfege (fixed Do) honoring the chosen spelling — handy for singers.
    var solfege: String {
        let sharp = ["도", "도#", "레", "레#", "미", "파", "파#", "솔", "솔#", "라", "라#", "시"]
        let flat  = ["도", "레♭", "레", "미♭", "미", "파", "솔♭", "솔", "라♭", "라", "시♭", "시"]
        return (prefersFlat ? flat : sharp)[pitchClass]
    }

    /// The accidental glyph to draw next to the notehead, or nil for naturals.
    var accidentalSymbol: String? {
        guard isAccidental else { return nil }
        return prefersFlat ? "\u{266D}" /* ♭ */ : "\u{266F}" /* ♯ */
    }

    /// Diatonic letter (C=0, D=1, E=2, F=3, G=4, A=5, B=6), honoring spelling.
    var letterIndex: Int {
        let sharpFold = [0,0,1,1,2,3,3,4,4,5,5,6]
        let flatFold  = [0,1,1,2,2,3,4,4,5,5,6,6]
        return (prefersFlat ? flatFold : sharpFold)[pitchClass]
    }

    /// Semitone offset from the natural of this note's own letter
    /// (+1 = sharp, -1 = flat, 0 = natural). Used to reconcile against a key.
    var alteration: Int {
        let naturalPc = [0,2,4,5,7,9,11][letterIndex]
        var d = pitchClass - naturalPc
        if d > 6 { d -= 12 }
        if d < -6 { d += 12 }
        return d
    }

    /// Scientific octave. MIDI 60 (Middle C) is octave 4.
    var octave: Int { midi / 12 - 1 }

    /// Display label like "C4", "C#5", or "Bb3".
    var label: String { "\(name)\(octave)" }

    /// True if this pitch is a black key (needs an accidental on a C-major staff).
    var isAccidental: Bool {
        [1, 3, 6, 8, 10].contains(pitchClass)
    }

    static let middleC = Pitch(midi: 60)
}

// MARK: - Duration

/// Rhythmic value of a note. `beats` is in quarter-note units so the
/// scheduler can convert to seconds with the current tempo.
enum NoteDuration: String, CaseIterable, Codable, Identifiable {
    case whole
    case half
    case quarter
    case eighth
    case sixteenth

    var id: String { rawValue }

    /// Length in quarter-note beats (4/4 assumption for the beat unit).
    var beats: Double {
        switch self {
        case .whole: return 4.0
        case .half: return 2.0
        case .quarter: return 1.0
        case .eighth: return 0.5
        case .sixteenth: return 0.25
        }
    }

    /// Short label for the toolbar.
    var symbol: String {
        switch self {
        case .whole: return "𝅝"
        case .half: return "𝅗𝅥"
        case .quarter: return "♩"
        case .eighth: return "♪"
        case .sixteenth: return "𝅘𝅥𝅯"
        }
    }

    var displayName: String {
        switch self {
        case .whole: return "온음표"
        case .half: return "2분음표"
        case .quarter: return "4분음표"
        case .eighth: return "8분음표"
        case .sixteenth: return "16분음표"
        }
    }
}

// MARK: - Key signature

/// A key signature expressed as a signed count of accidentals:
/// positive = that many sharps, negative = that many flats, 0 = C major.
/// Sharps are added in the order F C G D A E B (파 도 솔 레 라 미 시);
/// flats in the order B E A D G C F (시 미 라 레 솔 도 파).
struct KeySignature {
    var count: Int

    // Diatonic letter indices in the order accidentals are applied.
    static let sharpOrder = [3, 0, 4, 1, 5, 2, 6]   // F C G D A E B
    static let flatOrder  = [6, 2, 5, 1, 4, 0, 3]   // B E A D G C F

    /// Reference natural pitches (MIDI) where each glyph sits on a treble staff.
    static let sharpRefMidi = [77, 72, 79, 74, 69, 76, 71] // F5 C5 G5 D5 A4 E5 B4
    static let flatRefMidi  = [71, 76, 69, 74, 67, 72, 65] // B4 E5 A4 D5 G4 C5 F4

    /// The alteration (+1 sharp, -1 flat, 0) this key applies to a letter.
    func alteration(forLetter letter: Int) -> Int {
        if count > 0 {
            return Self.sharpOrder.prefix(min(count, 7)).contains(letter) ? 1 : 0
        } else if count < 0 {
            return Self.flatOrder.prefix(min(-count, 7)).contains(letter) ? -1 : 0
        }
        return 0
    }

    /// Full label, e.g. "G장조 (♯1)" or "B♭장조 (♭2)".
    var label: String {
        let sharpTonic = ["C","G","D","A","E","B","F♯","C♯"]
        let flatTonic  = ["C","F","B♭","E♭","A♭","D♭","G♭","C♭"]
        if count == 0 { return "다장조 C (조표 없음)" }
        if count > 0 { return "\(sharpTonic[min(count,7)])장조 (♯\(count))" }
        return "\(flatTonic[min(-count,7)])장조 (♭\(-count))"
    }

    /// Compact label for the header, e.g. "♯2" / "♭3" / "" for C major.
    var shortLabel: String {
        if count == 0 { return "" }
        return count > 0 ? "♯\(count)" : "♭\(-count)"
    }
}

// MARK: - ScoreNote

/// A single musical event placed on the staff.
///
/// A "chord" is modeled as several `ScoreNote`s that share the same
/// `beatOffset` (they start at the same time). This keeps the model flat
/// and makes both editing and scheduling trivial.
struct ScoreNote: Identifiable, Equatable, Codable {
    var id = UUID()
    var pitch: Pitch
    var duration: NoteDuration
    /// Start time of this note, measured in quarter-note beats from the
    /// very beginning of the score.
    var beatOffset: Double
    /// A rest occupies time but produces no sound.
    var isRest: Bool = false
    /// A dot lengthens the note by half its value (a dotted quarter = 1.5 beats).
    var dotted: Bool = false

    /// Effective length in quarter-note beats, accounting for any dot.
    var beats: Double { duration.beats * (dotted ? 1.5 : 1.0) }

    /// Human label like "4분음표" or "점4분음표".
    var durationLabel: String { (dotted ? "점" : "") + duration.displayName }
}

// MARK: - Score

/// The whole document. Notes are stored as a flat, time-ordered list.
struct Score: Codable {
    var title: String = "새 악보"
    /// Beats per minute (quarter note gets the beat).
    var tempo: Double = 90
    /// Numerator / denominator of the time signature, e.g. 4/4, 3/4, 6/8.
    var beatsPerMeasure: Int = 4
    var beatUnit: Int = 4
    /// Signed accidental count: + sharps, − flats, 0 = C major.
    var keySignature: Int = 0
    var notes: [ScoreNote] = []

    /// Total length of the score in beats (where the last sound ends).
    var totalBeats: Double {
        notes.map { $0.beatOffset + $0.beats }.max() ?? 0
    }

    /// How many quarter-note beats one measure spans, accounting for the
    /// beat unit (so 6/8 -> 3.0 quarter beats per measure).
    var quarterBeatsPerMeasure: Double {
        Double(beatsPerMeasure) * (4.0 / Double(beatUnit))
    }

    /// Notes grouped by their start beat — i.e. chords collapsed together.
    /// Returned sorted by time. Used by the scheduler.
    var chordGroups: [(beat: Double, notes: [ScoreNote])] {
        let grouped = Dictionary(grouping: notes) { $0.beatOffset }
        return grouped
            .map { (beat: $0.key, notes: $0.value) }
            .sorted { $0.beat < $1.beat }
    }
}

// MARK: - Measure validation

/// Tolerance for comparing beat positions/lengths (they're built from halves
/// and quarters, but floating point still drifts).
private let beatEpsilon = 1e-6

extension Score {
    /// One measure's worth of quarter-note beats (e.g. 4.0 for 4/4, 3.0 for 6/8).
    var measureCapacity: Double { quarterBeatsPerMeasure }

    /// Beats occupying each measure, keyed by measure index (0-based). A chord
    /// counts once as its longest member — matching how playback holds a group —
    /// and a group's full length is charged to the measure where it *starts*.
    func measureLoads() -> [Int: Double] {
        guard measureCapacity > 0 else { return [:] }
        var loads: [Int: Double] = [:]
        for g in chordGroups {
            let dur = g.notes.map { $0.beats }.max() ?? 0
            let measure = Int((g.beat + beatEpsilon) / measureCapacity)
            loads[measure, default: 0] += dur
        }
        return loads
    }

    /// Measures holding more than one bar's worth of beats — the "5 beats in a
    /// 4/4 bar" bug. Sorted ascending.
    var overfilledMeasures: [Int] {
        measureLoads()
            .filter { $0.value > measureCapacity + beatEpsilon }
            .keys.sorted()
    }

    /// Start beats of groups whose sounding length runs past the next barline
    /// (in real notation these should be split and tied). Sorted ascending.
    var barlineCrossings: [Double] {
        guard measureCapacity > 0 else { return [] }
        var result: [Double] = []
        for g in chordGroups {
            let dur = g.notes.map { $0.beats }.max() ?? 0
            guard dur > beatEpsilon else { continue }
            let startMeasure = Int((g.beat + beatEpsilon) / measureCapacity)
            let nextBar = Double(startMeasure + 1) * measureCapacity
            if g.beat + dur > nextBar + beatEpsilon {
                result.append(g.beat)
            }
        }
        return result.sorted()
    }

    /// True when every measure is exactly filled (no overflow) and nothing
    /// crosses a barline. Empty scores are trivially well-formed.
    var isWellFormed: Bool {
        overfilledMeasures.isEmpty && barlineCrossings.isEmpty
    }
}
