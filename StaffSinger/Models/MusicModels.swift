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

    init(midi: Int) {
        self.midi = max(0, min(127, midi))
    }

    /// Letter name without octave, using sharps. e.g. 60 -> "C", 61 -> "C#"
    var nameSharp: String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[((midi % 12) + 12) % 12]
    }

    /// Solfege (movable-less, fixed Do) — handy for the singer use-case.
    var solfege: String {
        let names = ["도", "도#", "레", "레#", "미", "파", "파#", "솔", "솔#", "라", "라#", "시"]
        return names[((midi % 12) + 12) % 12]
    }

    /// Scientific octave. MIDI 60 (Middle C) is octave 4.
    var octave: Int { midi / 12 - 1 }

    /// Display label like "C4" or "F#5".
    var label: String { "\(nameSharp)\(octave)" }

    /// True if this pitch is a black key (needs an accidental on a C-major staff).
    var isAccidental: Bool {
        let pc = ((midi % 12) + 12) % 12
        return [1, 3, 6, 8, 10].contains(pc)
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
    var notes: [ScoreNote] = []

    /// Total length of the score in beats (where the last sound ends).
    var totalBeats: Double {
        notes.map { $0.beatOffset + $0.duration.beats }.max() ?? 0
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
