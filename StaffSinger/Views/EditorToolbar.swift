//
//  EditorToolbar.swift
//  StaffSinger
//
//  The bottom editing bar: choose a note duration, toggle chord-stacking,
//  nudge the selected note up/down by a half-step or octave, add rests,
//  and delete. Designed for thumb reach on iPhone.
//

import SwiftUI

struct EditorToolbar: View {
    @ObservedObject var vm: ScoreViewModel
    @ObservedObject var audio: AudioEngine

    var body: some View {
        VStack(spacing: 10) {
            // Row 1: duration values
            HStack(spacing: 8) {
                ForEach(NoteDuration.allCases) { dur in
                    Button {
                        vm.selectedDuration = dur
                        if let id = vm.selectedNoteID {
                            vm.changeDuration(of: id, to: dur)
                        }
                    } label: {
                        // Unicode Musical Symbols (U+1D1xx) aren't in the system
                        // font, so we draw the note glyphs ourselves to guarantee
                        // they render on every device.
                        NoteDurationGlyph(duration: dur)
                            .frame(width: 44, height: 44)
                            .background(
                                vm.selectedDuration == dur
                                ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(vm.selectedDuration == dur
                                            ? Color.accentColor : .clear, lineWidth: 2))
                            .cornerRadius(10)
                            .foregroundColor(.primary)
                    }
                }
            }

            // Row 2: actions — centered as a group.
            HStack(spacing: 10) {
                Spacer(minLength: 0)

                // Chord mode toggle.
                Button {
                    vm.chordMode.toggle()
                } label: {
                    Label("화음", systemImage: vm.chordMode
                          ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(vm.chordMode ? Color.indigo.opacity(0.2) : Color(.systemGray6))
                        .foregroundColor(vm.chordMode ? .indigo : .primary)
                        .cornerRadius(10)
                }

                // Pitch nudges (only meaningful with a selection).
                Group {
                    nudgeButton("-8va", semis: -12)
                    nudgeButton("♭", semis: -1)
                    nudgeButton("♯", semis: +1)
                    nudgeButton("+8va", semis: +12)
                }
                .disabled(vm.selectedNoteID == nil)
                .opacity(vm.selectedNoteID == nil ? 0.4 : 1)

                // Small gap before the destructive/utility cluster.
                Spacer().frame(width: 8)

                Button { vm.addRest() } label: {
                    Image(systemName: "pause")
                        .frame(width: 38, height: 38)
                        .background(Color(.systemGray6)).cornerRadius(10)
                }

                Button(role: .destructive) { vm.deleteSelected() } label: {
                    Image(systemName: "trash")
                        .frame(width: 38, height: 38)
                        .background(Color.red.opacity(0.12))
                        .foregroundColor(.red).cornerRadius(10)
                }
                .disabled(vm.selectedNoteID == nil)
                .opacity(vm.selectedNoteID == nil ? 0.4 : 1)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // Background is provided by the enclosing editor panel.
    }

    private func nudgeButton(_ label: String, semis: Int) -> some View {
        Button {
            if let id = vm.selectedNoteID {
                vm.changePitch(of: id, semitones: semis)
            }
        } label: {
            Text(label)
                .font(.caption.weight(.bold))
                .frame(width: 42, height: 38)
                .background(Color(.systemGray6)).cornerRadius(10)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - NoteDurationGlyph

/// Draws a note (head + stem + flags) so the toolbar never depends on a font
/// shipping the Unicode Musical Symbols block.
struct NoteDurationGlyph: View {
    let duration: NoteDuration

    var body: some View {
        Canvas { ctx, size in
            let color = Color.primary
            let w = size.width, h = size.height

            // Note head: ~13 x 9 ellipse, slightly tilted, lower-left of the box.
            let headW: CGFloat = 13, headH: CGFloat = 9
            let headCenter = CGPoint(x: w * 0.40, y: h * 0.68)
            let headRect = CGRect(x: headCenter.x - headW / 2,
                                  y: headCenter.y - headH / 2,
                                  width: headW, height: headH)

            var headTransform = CGAffineTransform(translationX: headCenter.x, y: headCenter.y)
            headTransform = headTransform.rotated(by: -.pi / 9)
            headTransform = headTransform.translatedBy(x: -headCenter.x, y: -headCenter.y)
            let headPath = Path(ellipseIn: headRect).applying(headTransform)

            if isFilled {
                ctx.fill(headPath, with: .color(color))
            } else {
                ctx.stroke(headPath, with: .color(color), lineWidth: 1.8)
            }

            // Stem: up the right edge of the head (whole notes have none).
            if hasStem {
                let stemX = headRect.maxX - 0.5
                let stemTop = headCenter.y - h * 0.42
                var stem = Path()
                stem.move(to: CGPoint(x: stemX, y: headCenter.y))
                stem.addLine(to: CGPoint(x: stemX, y: stemTop))
                ctx.stroke(stem, with: .color(color), lineWidth: 1.8)

                // Flags for eighth (1) and sixteenth (2).
                for i in 0..<flagCount {
                    let y = stemTop + CGFloat(i) * 7
                    var flag = Path()
                    flag.move(to: CGPoint(x: stemX, y: y))
                    flag.addQuadCurve(to: CGPoint(x: stemX + 8, y: y + 11),
                                      control: CGPoint(x: stemX + 9, y: y + 2))
                    ctx.stroke(flag, with: .color(color), lineWidth: 1.8)
                }
            }
        }
        .frame(width: 26, height: 30)
    }

    private var isFilled: Bool {
        switch duration {
        case .whole, .half: return false
        default: return true
        }
    }

    private var hasStem: Bool { duration != .whole }

    private var flagCount: Int {
        switch duration {
        case .eighth: return 1
        case .sixteenth: return 2
        default: return 0
        }
    }
}
