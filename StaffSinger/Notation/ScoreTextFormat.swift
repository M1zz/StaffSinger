//
//  ScoreTextFormat.swift
//  StaffSinger
//
//  A tiny, human-writable text notation so a score can be carried in plain
//  text. The intended flow: a user photographs a score, asks an AI to read it
//  and write it out in *this* format, copies the result, and pastes it into the
//  app — where `parse` turns it back into notes on the staff. `serialize` does
//  the reverse, so the current score can be copied out as a worked example to
//  hand the AI.
//
//  One note is one whitespace/comma-separated token, e.g. `4옥도8분음`:
//    [점][셋잇단] [옥타브]옥 [계이름][임시표] [길이]
//      • 옥타브   : 숫자 + "옥" (가온다 = 4옥). 생략하면 직전 음의 옥타브를 유지.
//      • 계이름   : 도 레 미 파 솔 라 시  (또는 C D E F G A B)
//      • 임시표   : # / ♯ (올림), b / ♭ (내림). 없으면 생략.
//      • 길이     : 온음 · 2분음 · 4분음 · 8분음 · 16분음. 생략하면 직전 길이를 유지.
//      • 점음표   : 앞에 "점"      (점4분음)
//      • 셋잇단   : 앞에 "셋잇단"  (셋잇단8분음)
//      • 쉼표     : 계이름 대신 "쉼"  (4분쉼, 8분쉼)
//
//  Outside Korean the app uses a language-neutral letter notation instead,
//  which every AI and every reader can write without knowing Korean:
//    [음이름][임시표][옥타브]:[길이][. 점][t 셋잇단]   e.g. `C4:4`, `F#4:8.`, `Bb3:8t`
//    쉼표는 `R:4`. 옥타브나 `:길이` 를 빼면 직전 값을 그대로 쓴다.
//  `parse` reads both notations in any language, so a pasted text never
//  depends on which language the phone is set to.
//

import Foundation

enum ScoreTextFormat {

    /// Korean users get the Korean notation (`4옥도8분음`); everyone else gets
    /// the letter notation (`C4:8`), so no one is asked to type a script they
    /// can't read.
    static var usesKoreanNotation: Bool {
        Bundle.main.preferredLocalizations.first?.hasPrefix("ko") ?? false
    }

    /// The instruction block a user copies and hands to an AI ("read this score
    /// and write it in this format"), in the notation this language uses.
    static var ruleText: String {
        usesKoreanNotation ? koreanRuleText : letterRuleText
    }

    /// The letter-notation rule, translated per language. Kept in sync with
    /// `parseLetterToken` below.
    static var letterRuleText: String {
        String(localized: "score.rule.letters", defaultValue: """
        아래 규칙으로 악보를 텍스트로 적어줘. 음표 하나를 한 덩어리로 쓰고, 음표끼리는 공백으로 구분해. 설명 없이 음표 텍스트만 한 줄로 줘.

        음표 = [음이름][임시표][옥타브]:[길이][점·셋잇단]
        · 음이름: C D E F G A B
        · 임시표: 올림 #, 내림 b (없으면 생략)
        · 옥타브: 숫자 (가온다=C4). 생략하면 직전 옥타브 유지
        · 길이: 1 온음표, 2 2분음표, 4 4분음표, 8 8분음표, 16 16분음표. ":길이"를 생략하면 직전 길이 유지
        · 점음표는 길이 뒤에 "." (C4:4.), 셋잇단음표는 "t" (C4:8t)
        · 쉼표는 음이름 대신 R (R:4, R:8)

        예시) C4:4 D4:4 E4:8 F4:8 G4:2
        """)
    }

    /// The Korean notation's rule (shown only in Korean).
    static let koreanRuleText = """
    아래 규칙으로 악보를 텍스트로 적어줘. 음표 하나를 한 덩어리로 쓰고, 음표끼리는 \
    공백으로 구분해. 설명 없이 음표 텍스트만 한 줄로 줘.

    음표 = [옥타브]옥[계이름][임시표][길이]
    · 옥타브: 숫자+"옥" (가온다=4옥). 생략하면 직전 옥타브 유지
    · 계이름: 도 레 미 파 솔 라 시 (또는 C D E F G A B)
    · 임시표: 올림 #, 내림 b (없으면 생략)
    · 길이: 온음 / 2분음 / 4분음 / 8분음 / 16분음
    · 점음표는 앞에 "점" (점4분음), 셋잇단음표는 앞에 "셋잇단" (셋잇단8분음)
    · 쉼표는 계이름 대신 "쉼" (4분쉼, 8분쉼)

    예시) 4옥도4분음 4옥레4분음 4옥미8분음 4옥파8분음 4옥솔2분음
    """

    // MARK: - Pitch tables

    /// Korean solfege → semitone offset within an octave (C = 0).
    private static let solfege: [(name: String, semitone: Int)] = [
        ("도", 0), ("레", 2), ("미", 4), ("파", 5), ("솔", 7), ("라", 9), ("시", 11)
    ]
    /// English letter → semitone offset within an octave.
    private static let letters: [Character: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
    ]

    // MARK: - Parse

    /// Turn pasted text into a sequential, single-voice melody. Notes are laid
    /// end to end starting at beat 0 (layer 0), exactly how the editor appends.
    /// Tokens that don't yield a pitch/rest are skipped rather than failing the
    /// whole paste, so one stray word doesn't lose the rest of the line.
    static func parse(_ text: String) -> [ScoreNote] {
        var notes: [ScoreNote] = []
        var cursor = 0.0
        var lastOctave = 4
        var lastDuration: NoteDuration = .quarter

        let separators = CharacterSet(charactersIn: " \t\n\r,/|·\u{00B7}")
        for raw in text.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            guard let note = parseToken(token,
                                        startBeat: cursor,
                                        lastOctave: &lastOctave,
                                        lastDuration: &lastDuration) else { continue }
            notes.append(note)
            cursor += note.beats
        }
        return notes
    }

    /// Parse one token into a note/rest, carrying the running octave & duration
    /// forward so they can be omitted on later tokens.
    private static func parseToken(_ token: String,
                                   startBeat: Double,
                                   lastOctave: inout Int,
                                   lastDuration: inout NoteDuration) -> ScoreNote? {
        if let note = parseLetterToken(token, startBeat: startBeat,
                                       lastOctave: &lastOctave, lastDuration: &lastDuration) {
            return note
        }
        let dotted = token.contains("점")
        let triplet = token.contains("셋잇단")
        let isRest = token.contains("쉼")

        // Octave: digits immediately before "옥".
        if let oct = firstInt(in: token, before: "옥") { lastOctave = oct }
        let octave = lastOctave

        // Duration: "온"(음) = whole, otherwise digits before "분".
        if token.contains("온") {
            lastDuration = .whole
        } else if let denom = firstInt(in: token, before: "분"),
                  let dur = duration(forDenominator: denom) {
            lastDuration = dur
        }
        let duration = lastDuration

        if isRest {
            return ScoreNote(pitch: .middleC, duration: duration,
                             beatOffset: startBeat, isRest: true,
                             dotted: dotted, triplet: triplet)
        }

        guard let (semitone, alteration) = pitch(in: token) else { return nil }
        let midi = (octave + 1) * 12 + semitone + alteration
        let p = Pitch(midi: midi, prefersFlat: alteration < 0)
        return ScoreNote(pitch: p, duration: duration,
                         beatOffset: startBeat, dotted: dotted, triplet: triplet)
    }

    /// The letter notation: `C4:4`, `F#4:8.`, `Bb3:8t`, `R:4`, or just `E` /
    /// `D5` to keep the previous length. Returns nil for anything else so the
    /// Korean reading gets its turn.
    private static let letterPattern = try! NSRegularExpression(
        pattern: "^(?:([A-Ga-g])([#\u{266F}b\u{266D}]?)(\\d)?|([Rr]))(?::(16|8|4|2|1))?([.t]*)$")

    private static func parseLetterToken(_ token: String,
                                         startBeat: Double,
                                         lastOctave: inout Int,
                                         lastDuration: inout NoteDuration) -> ScoreNote? {
        let ns = token as NSString
        guard let m = letterPattern.firstMatch(in: token, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        if let denom = group(5).flatMap(Int.init), let dur = duration(forDenominator: denom) {
            lastDuration = dur
        }
        let marks = group(6) ?? ""
        let dotted = marks.contains(".")
        let triplet = marks.contains("t")

        if group(4) != nil {
            return ScoreNote(pitch: .middleC, duration: lastDuration,
                             beatOffset: startBeat, isRest: true,
                             dotted: dotted, triplet: triplet)
        }
        guard let letter = group(1)?.uppercased().first, let semitone = letters[letter] else { return nil }
        if let oct = group(3).flatMap(Int.init) { lastOctave = oct }
        let acc = group(2) ?? ""
        let alteration = (acc == "#" || acc == "\u{266F}") ? 1 : (acc.isEmpty ? 0 : -1)
        let midi = (lastOctave + 1) * 12 + semitone + alteration
        return ScoreNote(pitch: Pitch(midi: midi, prefersFlat: alteration < 0),
                         duration: lastDuration, beatOffset: startBeat,
                         dotted: dotted, triplet: triplet)
    }

    /// Find the first pitch in a token: its semitone offset plus any accidental
    /// (+1 sharp / −1 flat) written right after the note name. Korean solfege is
    /// tried first; an uppercase English letter is the fallback (lowercase is
    /// avoided so a flat "b" is never mistaken for the note B).
    private static func pitch(in token: String) -> (semitone: Int, alteration: Int)? {
        for entry in solfege {
            if let r = token.range(of: entry.name) {
                return (entry.semitone, accidental(after: r.upperBound, in: token))
            }
        }
        for (i, ch) in token.enumerated() {
            if let semi = letters[ch] {
                let idx = token.index(token.startIndex, offsetBy: i + 1)
                return (semi, accidental(after: idx, in: token))
            }
        }
        return nil
    }

    /// Accidental glyph sitting at `index`: +1 sharp, −1 flat, 0 none.
    private static func accidental(after index: String.Index, in token: String) -> Int {
        guard index < token.endIndex else { return 0 }
        let rest = token[index...]
        if rest.hasPrefix("#") || rest.hasPrefix("\u{266F}") || rest.hasPrefix("\u{FF03}")
            || rest.hasPrefix("샵") { return 1 }
        if rest.hasPrefix("b") || rest.hasPrefix("\u{266D}") || rest.hasPrefix("플랫") { return -1 }
        return 0
    }

    /// The integer made of consecutive digits ending just before `marker`,
    /// e.g. `firstInt(in: "16분음", before: "분") == 16`.
    private static func firstInt(in token: String, before marker: Character) -> Int? {
        guard let markerIdx = token.firstIndex(of: marker) else { return nil }
        var digits = ""
        var i = markerIdx
        while i > token.startIndex {
            let prev = token.index(before: i)
            let ch = token[prev]
            if ch.isNumber { digits.insert(ch, at: digits.startIndex); i = prev } else { break }
        }
        return Int(digits)
    }

    private static func duration(forDenominator denom: Int) -> NoteDuration? {
        switch denom {
        case 1: return .whole
        case 2: return .half
        case 4: return .quarter
        case 8: return .eighth
        case 16: return .sixteenth
        default: return nil
        }
    }

    // MARK: - Serialize

    /// Render the score's notes (time-ordered, melody only) back into the text
    /// format — useful as a concrete example to paste to an AI, or to copy a
    /// score out as text.
    static func serialize(_ score: Score) -> String {
        serialize(score, korean: usesKoreanNotation)
    }

    /// `korean: false` writes the letter notation (`C4:8`) used outside Korean.
    static func serialize(_ score: Score, korean: Bool) -> String {
        score.notes
            .sorted { $0.beatOffset < $1.beatOffset }
            .map { korean ? token(for: $0) : letterToken(for: $0) }
            .joined(separator: " ")
    }

    private static func letterToken(for note: ScoreNote) -> String {
        let length = ":\(denominator(note.duration))"
            + (note.dotted ? "." : "") + (note.triplet ? "t" : "")
        if note.isRest { return "R" + length }
        return note.pitch.name + "\(note.pitch.octave)" + length
    }

    private static func denominator(_ d: NoteDuration) -> Int {
        switch d {
        case .whole: return 1
        case .half: return 2
        case .quarter: return 4
        case .eighth: return 8
        case .sixteenth: return 16
        }
    }

    private static func token(for note: ScoreNote) -> String {
        let prefix: String = (note.triplet ? "셋잇단" : "") + (note.dotted ? "점" : "")
        let length: String = lengthCore(note.duration)
        if note.isRest {
            return prefix + length + "쉼"
        }
        let p = note.pitch
        // White keys map straight to a solfege name; black keys have no exact
        // entry, so spell them as the nearest natural plus an accidental glyph.
        let head: String
        if p.isAccidental {
            let acc = p.prefersFlat ? "b" : "#"
            head = naturalSolfege(p) + acc
        } else {
            head = solfege.first { $0.semitone == pitchClass(p) }?.name ?? p.name
        }
        return prefix + "\(p.octave)" + "옥" + head + length + "음"
    }

    private static func pitchClass(_ p: Pitch) -> Int { ((p.midi % 12) + 12) % 12 }

    /// Solfege of the natural a sharp sits above / a flat sits below.
    private static func naturalSolfege(_ p: Pitch) -> String {
        let naturalPc = [0, 2, 4, 5, 7, 9, 11][p.letterIndex]
        return solfege.first { $0.semitone == naturalPc }?.name ?? p.name
    }

    /// "온" / "2분" / "4분" … — the part shared by note ("…음") and rest ("…쉼").
    private static func lengthCore(_ d: NoteDuration) -> String {
        switch d {
        case .whole: return "온"
        case .half: return "2분"
        case .quarter: return "4분"
        case .eighth: return "8분"
        case .sixteenth: return "16분"
        }
    }
}
