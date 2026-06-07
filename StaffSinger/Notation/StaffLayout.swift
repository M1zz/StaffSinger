//
//  StaffLayout.swift
//  StaffSinger
//
//  Pure geometry: converts a Pitch into a vertical Y position on a treble
//  staff, and back from a tapped Y into the nearest diatonic pitch. Kept
//  free of SwiftUI so it's easy to reason about and test.
//

import Foundation
import CoreGraphics

struct StaffLayout {

    /// Vertical distance between two adjacent staff lines.
    let lineSpacing: CGFloat
    /// Y of the TOP staff line (the F5 line on a treble staff).
    let topLineY: CGFloat

    init(lineSpacing: CGFloat = 14, topLineY: CGFloat = 60) {
        self.lineSpacing = lineSpacing
        self.topLineY = topLineY
    }

    // We position by "staff steps": each step is half a line spacing and
    // corresponds to one diatonic step (line -> space -> line ...).
    //
    // Reference: the top line of a treble staff is F5 (MIDI 77).
    // Each diatonic step downward adds half a lineSpacing in Y.
    private static let topLineMidi = 77  // F5

    /// The diatonic "staff position" of a pitch — number of diatonic steps
    /// from F5, counting only the 7 letter names (accidentals share a slot).
    static func diatonicSteps(from midi: Int) -> Int {
        // Map a midi note to a diatonic index (C=0,D=1,E=2,F=3,G=4,A=5,B=6).
        let pc = ((midi % 12) + 12) % 12
        let pcToDiatonic = [0,0,1,1,2,3,3,4,4,5,5,6] // sharps fold to letter below
        let octave = midi / 12 - 1
        let diatonicIndex = pcToDiatonic[pc] + octave * 7

        let topPc = ((topLineMidi % 12) + 12) % 12
        let topOctave = topLineMidi / 12 - 1
        let topDiatonic = pcToDiatonic[topPc] + topOctave * 7

        return topDiatonic - diatonicIndex // positive = below the top line
    }

    /// Y position (center of the notehead) for a pitch.
    func y(for pitch: Pitch) -> CGFloat {
        let steps = CGFloat(Self.diatonicSteps(from: pitch.midi))
        return topLineY + steps * (lineSpacing / 2)
    }

    /// The five staff line Y positions (top to bottom).
    var lineYs: [CGFloat] {
        (0..<5).map { topLineY + CGFloat($0) * lineSpacing }
    }

    var bottomLineY: CGFloat { topLineY + 4 * lineSpacing }

    /// Given a tapped Y, return the nearest natural pitch on the staff.
    func pitch(forY y: CGFloat) -> Pitch {
        let stepsFloat = (y - topLineY) / (lineSpacing / 2)
        let steps = Int(stepsFloat.rounded())
        return Self.pitch(diatonicStepsBelowTop: steps)
    }

    /// Inverse of `diatonicSteps`: build the natural pitch at a given step.
    static func pitch(diatonicStepsBelowTop steps: Int) -> Pitch {
        let topPc = ((topLineMidi % 12) + 12) % 12
        let topOctave = topLineMidi / 12 - 1
        let pcToDiatonic = [0,0,1,1,2,3,3,4,4,5,5,6]
        let topDiatonic = pcToDiatonic[topPc] + topOctave * 7
        let targetDiatonic = topDiatonic - steps

        let diatonicToSemitone = [0,2,4,5,7,9,11] // C D E F G A B
        let octave = Int(floor(Double(targetDiatonic) / 7.0))
        let within = ((targetDiatonic % 7) + 7) % 7
        let midi = (octave + 1) * 12 + diatonicToSemitone[within]
        return Pitch(midi: midi)
    }

    /// Ledger line Y positions needed to reach a notehead above/below staff.
    func ledgerLineYs(for pitch: Pitch) -> [CGFloat] {
        let noteY = y(for: pitch)
        var ys: [CGFloat] = []
        // Below the staff.
        var ly = bottomLineY + lineSpacing
        while ly <= noteY + 0.5 {
            ys.append(ly)
            ly += lineSpacing
        }
        // Above the staff.
        ly = topLineY - lineSpacing
        while ly >= noteY - 0.5 {
            ys.append(ly)
            ly -= lineSpacing
        }
        return ys
    }
}
