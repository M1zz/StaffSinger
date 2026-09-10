//
//  SpokenSolfege.swift
//  StaffSinger
//
//  Turning spoken 계이름 into notes — the pure, testable half of voice
//  dictation (no AVFoundation here, so it can be reasoned about and unit
//  tested on its own).
//
//  The premise: a sight-reading student reading a score out loud already says
//  "도 레 미 파" *in time*. So one utterance carries both halves of the
//  problem — the syllable says WHICH note, the moment it was said says WHEN.
//  There is no separate rhythm-entry step: `notes(from:)` takes the recognized
//  words with their timestamps and quantizes them onto the score's beat grid,
//  deriving each note's length from the gap to the next syllable.
//
//  Two things make spoken solfege ambiguous, and both are handled here:
//    • Speech recognition mangles isolated syllables ("레"→"래", "파"→"화"),
//      so `token(for:)` matches a hand-built homophone list — exactly, never
//      by substring, so ordinary speech never becomes a note.
//    • Fixed-do solfege carries no octave. `resolveOctave` picks the octave
//      nearest the previous note, which gets stepwise motion and the 시→도
//      turn right; a leap wider than a fourth needs "높은/낮은".
//

import Foundation

// MARK: - Input

/// One sound event heard during dictation: what was said, and when.
/// `time` is seconds from the downbeat (i.e. after the count-in), so a
/// negative time means the user came in early.
struct SpokenEvent: Equatable {
    var word: String
    var time: Double
    /// How long the recognizer thinks the word took. Used only to spread a
    /// run-on token ("도레미") across its own span.
    var duration: Double = 0
}

// MARK: - Vocabulary & quantization

enum SpokenSolfege {

    /// How finely spoken timing is snapped. `.free` throws timing away and
    /// lays the notes out back to back at the current tool duration — the
    /// escape hatch for users who'd rather set rhythm by hand.
    enum Grid: Double, CaseIterable, Identifiable {
        case quarter = 1.0
        case eighth = 0.5
        case sixteenth = 0.25
        case free = 0

        var id: Double { rawValue }

        var label: String {
            switch self {
            case .quarter: return "4분"
            case .eighth: return "8분"
            case .sixteenth: return "16분"
            case .free: return "리듬 없이"
            }
        }
    }

    /// What one recognized word means musically.
    enum Token: Equatable {
        /// `semitone` is the natural pitch class (C=0), `alteration` the
        /// accidental spoken after it, `octave` an explicitly stated octave
        /// ("4옥"), and `nudge` a 높은/낮은 modifier in octaves.
        case pitch(semitone: Int, alteration: Int, octave: Int?, nudge: Int)
        case rest
    }

    // MARK: Vocabulary

    /// Solfege syllable → natural pitch class. Ordered so longer spellings are
    /// tried first when splitting a run-on token.
    private static let syllables: [(text: String, semitone: Int)] = [
        ("도", 0), ("레", 2), ("미", 4), ("파", 5), ("솔", 7), ("라", 9), ("시", 11)
    ]

    /// Everything the recognizer plausibly hears for each syllable. Korean
    /// speech recognition is trained on words, not isolated note names, so a
    /// bare "레" often comes back as "래"/"네" and "파" as "화"/"바". English
    /// note letters are accepted too, since the recognizer sometimes latches
    /// onto those.
    ///
    /// Spellings that are ordinary high-frequency Korean words are deliberately
    /// left out ("나", "이", "지"): matching them would turn ordinary speech
    /// into notes, and a missed syllable is far cheaper to fix than a phantom
    /// one. For the same reason "씨" is read as 시, never as English "C".
    private static let homophones: [(spellings: [String], semitone: Int)] = [
        (["도", "또", "도오", "돌", "do", "doh", "c"], 0),
        (["레", "래", "네", "래이", "re", "ray", "d", "디"], 2),
        (["미", "밈", "미이", "mi", "me", "e"], 4),
        (["파", "화", "바", "빠", "팔", "fa", "f", "에프"], 5),
        (["솔", "쏠", "소", "골", "so", "sol", "soh", "g"], 7),
        (["라", "랄", "la", "lah", "a", "에이"], 9),
        (["시", "씨", "히", "치", "실", "ti", "si", "b", "비"], 11)
    ]

    /// Words that mean "silence for this beat".
    private static let restWords = ["쉼", "쉬", "쉬어", "쉬고", "숨", "쉼표", "rest"]

    /// The vocabulary handed to the recognizer as `contextualStrings` so it
    /// biases toward note names instead of ordinary Korean words.
    static var contextualStrings: [String] {
        syllables.map(\.text) + ["높은", "낮은", "쉼", "샵", "플랫", "올림", "내림"]
    }

    // MARK: Word → token

    /// Best-effort reading of one recognized word. Returns nil for words that
    /// carry no musical meaning, so stray speech is dropped instead of
    /// derailing the whole take.
    static func token(for rawWord: String) -> Token? {
        let word = normalize(rawWord)
        guard !word.isEmpty else { return nil }
        if restWords.contains(word) { return .rest }

        // Modifiers can ride along on the same word ("높은도", "도샵").
        var nudge = 0
        if word.contains("높은") || word.contains("윗") { nudge += 1 }
        if word.contains("낮은") || word.contains("아랫") { nudge -= 1 }

        var alteration = 0
        if word.contains("샵") || word.contains("올림") || word.contains("#") { alteration = 1 }
        if word.contains("플랫") || word.contains("내림") || word.contains("♭") { alteration = -1 }

        let octave = explicitOctave(in: word)

        guard let semitone = semitone(in: core(of: word)) else { return nil }
        return .pitch(semitone: semitone, alteration: alteration, octave: octave, nudge: nudge)
    }

    /// The word with every modifier we already consumed stripped off, leaving
    /// just the note name to match. "높은도샵" → "도", "4옥솔" → "솔".
    private static func core(of word: String) -> String {
        var core = word
        for affix in ["높은", "낮은", "윗", "아랫", "샵", "플랫", "올림", "내림", "#", "♭"] {
            core = core.replacingOccurrences(of: affix, with: "")
        }
        // Drop an explicit octave prefix along with its digits.
        if let marker = core.firstIndex(of: "옥") {
            core = String(core[core.index(after: marker)...])
        }
        return core.trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased, stripped of spaces and punctuation the recognizer adds.
    private static func normalize(_ word: String) -> String {
        word.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted
                .subtracting(CharacterSet(charactersIn: "#♭"))
                .union(CharacterSet(charactersIn: " \t\n")))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The pitch class this word names.
    ///
    /// Matching is exact rather than substring-based: a loose `contains` turns
    /// every stray "그래서" into 레, and inventing notes out of ordinary speech
    /// is much worse than dropping a syllable — a missed note is one tap to
    /// add, a phantom one has to be spotted first.
    ///
    /// The single concession is a two-character word opening with a *canonical*
    /// syllable ("도요", "라랑"), which is how the recognizer renders a sung
    /// note with a tail. Homophones are excluded from that rule on purpose:
    /// "네" alone is a plausible 레, but "네네" is just someone saying yes.
    private static func semitone(in word: String) -> Int? {
        guard !word.isEmpty else { return nil }
        for entry in homophones where entry.spellings.contains(word) {
            return entry.semitone
        }
        guard word.count == 2, let first = word.first else { return nil }
        return syllables.first { $0.text == String(first) }?.semitone
    }

    /// Digits sitting just before "옥" ("4옥도" → 4).
    private static func explicitOctave(in word: String) -> Int? {
        guard let marker = word.firstIndex(of: "옥") else { return nil }
        var digits = ""
        var i = marker
        while i > word.startIndex {
            let prev = word.index(before: i)
            guard word[prev].isNumber else { break }
            digits.insert(word[prev], at: digits.startIndex)
            i = prev
        }
        return Int(digits)
    }

    /// Split a run-on token ("도레미") into its syllables. Returns a single
    /// element for ordinary words, so callers can treat every word uniformly.
    static func split(_ rawWord: String) -> [String] {
        let word = normalize(rawWord)
        // Only split pure runs of Korean solfege; anything else stays whole so
        // modifiers like "높은도" survive.
        let names = Set(syllables.map(\.text))
        guard word.count > 1, word.allSatisfy({ names.contains(String($0)) }) else {
            return [rawWord]
        }
        return word.map(String.init)
    }

    // MARK: - Events → notes

    /// Quantize spoken events onto the beat grid and hand back placed notes.
    ///
    /// Each note's length is the distance to the *next* syllable — that is what
    /// makes a single utterance carry the rhythm. The last note is stretched to
    /// the end of its measure so a take always closes on a bar line.
    ///
    /// - Parameters:
    ///   - tempo: BPM the count-in ran at; converts seconds to beats.
    ///   - grid: snap resolution, or `.free` to ignore timing entirely.
    ///   - baseOctave: octave the first note lands in.
    ///   - autoOctave: when true, later notes take the octave that keeps the
    ///     interval smallest; when false everything stays in `baseOctave`.
    ///   - measureBeats: one bar's worth of beats, used to close out the take.
    ///   - capacityBeats: total beats the staff can show (two measures).
    static func notes(from events: [SpokenEvent],
                      tempo: Double,
                      grid: Grid,
                      baseOctave: Int,
                      autoOctave: Bool,
                      measureBeats: Double,
                      capacityBeats: Double,
                      freeDuration: NoteDuration = .quarter) -> [ScoreNote] {

        // 1. Expand words into tokens, keeping each one's time.
        var placed: [(token: Token, beat: Double)] = []
        let secondsPerBeat = 60.0 / max(20.0, tempo)
        for event in events {
            let parts = split(event.word)
            let span = parts.count > 1 ? event.duration / Double(parts.count) : 0
            for (i, part) in parts.enumerated() {
                guard let token = token(for: part) else { continue }
                let time = event.time + span * Double(i)
                placed.append((token, time / secondsPerBeat))
            }
        }
        guard !placed.isEmpty else { return [] }

        // 2. Put them on the grid. `.free` discards the timing and lays the
        //    notes end to end; otherwise every start snaps to the nearest
        //    subdivision and collisions are pushed forward so no syllable is
        //    silently swallowed by its neighbour.
        var starts: [Double] = []
        if grid == .free {
            let step = freeDuration.beats
            starts = placed.indices.map { Double($0) * step }
        } else {
            let step = grid.rawValue
            var previous = -Double.greatestFiniteMagnitude
            for entry in placed {
                var slot = (max(0, entry.beat) / step).rounded() * step
                if slot <= previous + 1e-6 { slot = previous + step }
                starts.append(slot)
                previous = slot
            }
        }

        // 3. Keep only what fits on the two visible measures.
        var kept: [(token: Token, start: Double)] = []
        for (entry, start) in zip(placed, starts) where start < capacityBeats - 1e-6 {
            kept.append((entry.token, start))
        }
        guard !kept.isEmpty else { return [] }

        // 4. Length = gap to the next syllable, so the rhythm falls out of the
        //    timing for free. The final note has no next syllable to measure
        //    against, so it runs to the end of ITS OWN bar — stretching it to
        //    the end of the staff instead would turn a closing quarter note
        //    into a whole note.
        var result: [ScoreNote] = []
        var previousMidi: Int? = nil
        let bar = measureBeats > 0 ? measureBeats : capacityBeats
        for (i, entry) in kept.enumerated() {
            let next: Double
            if i + 1 < kept.count {
                next = kept[i + 1].start
            } else {
                let barEnd = (floor((entry.start + 1e-6) / bar) + 1) * bar
                next = min(barEnd, capacityBeats)
            }
            let (duration, dotted) = value(forBeats: next - entry.start)

            switch entry.token {
            case .rest:
                result.append(ScoreNote(pitch: .middleC, duration: duration,
                                        beatOffset: entry.start, isRest: true,
                                        dotted: dotted))
            case let .pitch(semitone, alteration, octave, nudge):
                let midi = resolveOctave(semitone: semitone, alteration: alteration,
                                         explicit: octave, nudge: nudge,
                                         baseOctave: baseOctave,
                                         previous: autoOctave ? previousMidi : nil)
                previousMidi = midi
                result.append(ScoreNote(pitch: Pitch(midi: midi, prefersFlat: alteration < 0),
                                        duration: duration, beatOffset: entry.start,
                                        dotted: dotted))
            }
        }
        return result
    }

    /// Where a syllable sits in absolute pitch.
    ///
    /// With no previous note (or auto-octave off) it lands in `baseOctave`.
    /// Otherwise it takes the octave that keeps it within a fourth of the note
    /// before — the range that covers steps and the common small leaps, so
    /// "시 도" reads as a rising semitone rather than a falling seventh. Wider
    /// leaps need an explicit "높은/낮은", which is what `nudge` carries.
    private static func resolveOctave(semitone: Int, alteration: Int,
                                      explicit: Int?, nudge: Int,
                                      baseOctave: Int, previous: Int?) -> Int {
        let octave = explicit ?? baseOctave
        var midi = (octave + 1) * 12 + semitone + alteration

        if explicit == nil, let previous {
            // Walk to the octave nearest the previous note. Ties (a tritone
            // either way) resolve upward, matching how melodies are read.
            while midi - previous > 5 { midi -= 12 }
            while previous - midi > 6 { midi += 12 }
        }
        return max(0, min(127, midi + nudge * 12))
    }

    /// Standard note values, longest first, so a length can be matched to the
    /// closest writable duration (with a dot where that fits better).
    private static let values: [(beats: Double, duration: NoteDuration, dotted: Bool)] = [
        (4.0, .whole, false), (3.0, .half, true), (2.0, .half, false),
        (1.5, .quarter, true), (1.0, .quarter, false),
        (0.75, .eighth, true), (0.5, .eighth, false),
        (0.25, .sixteenth, false)
    ]

    /// The writable note value closest to a measured length in beats.
    static func value(forBeats beats: Double) -> (NoteDuration, Bool) {
        let best = values.min { abs($0.beats - beats) < abs($1.beats - beats) }!
        return (best.duration, best.dotted)
    }
}
