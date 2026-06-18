//
//  PianoKeyboard.swift
//  StaffSinger
//
//  A two-octave on-screen piano for quick note entry: tap a key to add a note
//  at the current duration. Octave shift buttons move the visible range. White
//  keys show their solfège (도레미) so singers can find pitches by name.
//

import SwiftUI

struct PianoKeyboard: View {
    /// Lowest octave shown (two octaves are drawn from here).
    @Binding var startOctave: Int
    /// Tapping a key hands back the exact pitch to place.
    let onPitch: (Pitch) -> Void

    private let octavesShown = 2
    private let minOctave = 1
    private let maxOctave = 6

    // White-key semitones within an octave: C D E F G A B.
    private let whiteSemis = [0, 2, 4, 5, 7, 9, 11]
    // Black keys sit after these LOCAL white indices: C(0) D(1) — F(3) G(4) A(5).
    private let blackAfterLocal = [0, 1, 3, 4, 5]

    /// White-key MIDI numbers for the visible range.
    private var whiteMidis: [Int] {
        var out: [Int] = []
        for o in 0..<octavesShown {
            let octave = startOctave + o
            for s in whiteSemis { out.append((octave + 1) * 12 + s) }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 8) {
            octaveButton(systemName: "chevron.left", to: startOctave - 1,
                         enabled: startOctave > minOctave)

            GeometryReader { geo in
                let whites = whiteMidis
                let n = max(1, whites.count)
                let w = geo.size.width / CGFloat(n)
                let blackW = w * 0.62
                let blackH = geo.size.height * 0.6

                ZStack(alignment: .topLeading) {
                    // White keys.
                    HStack(spacing: 0) {
                        ForEach(whites, id: \.self) { midi in
                            whiteKey(midi: midi, width: w)
                        }
                    }
                    // Black keys, overlaid between the whites that have one.
                    ForEach(blackMidis(whites: whites), id: \.midi) { item in
                        blackKey(midi: item.midi)
                            .frame(width: blackW, height: blackH)
                            .position(x: CGFloat(item.whiteIndex + 1) * w,
                                      y: blackH / 2)
                    }
                }
            }

            octaveButton(systemName: "chevron.right", to: startOctave + 1,
                         enabled: startOctave + octavesShown - 1 < maxOctave)
        }
        .frame(height: 116)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Keys

    private func whiteKey(midi: Int, width: CGFloat) -> some View {
        let p = Pitch(midi: midi)
        return Button { onPitch(p) } label: {
            VStack {
                Spacer()
                Text(p.solfege)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                // Octave marker on each C so the range is readable.
                if midi % 12 == 0 {
                    Text("\(p.octave)").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 6)
            .frame(width: width, height: 116)
            .background(Color.white)
            .overlay(Rectangle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func blackKey(midi: Int) -> some View {
        Button { onPitch(Pitch(midi: midi)) } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Black-key MIDI numbers paired with the white index they sit just right of.
    private func blackMidis(whites: [Int]) -> [(midi: Int, whiteIndex: Int)] {
        var out: [(Int, Int)] = []
        for o in 0..<octavesShown {
            for local in blackAfterLocal {
                let whiteIndex = o * 7 + local
                guard whiteIndex < whites.count else { continue }
                out.append((whites[whiteIndex] + 1, whiteIndex))
            }
        }
        return out.map { (midi: $0.0, whiteIndex: $0.1) }
    }

    private func octaveButton(systemName: String, to target: Int, enabled: Bool) -> some View {
        Button {
            startOctave = max(minOctave, min(maxOctave - octavesShown + 1, target))
        } label: {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 34, height: 116)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .foregroundColor(.primary)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
