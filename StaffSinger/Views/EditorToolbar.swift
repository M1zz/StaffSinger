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
            // Row 0: key signature — build ♯/♭ scores at a tap. Tapping ♯ adds the
            // next sharp (파 도 솔 레 라 미 시 order), ♭ the next flat (시 미 라 레
            // 솔 도 파). New notes on white-key lines pick up the key automatically.
            keyRow

            // Row 1: duration values + dot toggle + voice (layer) picker
            HStack(spacing: 8) {
                ForEach(NoteDuration.allCases) { dur in
                    durationButton(dur)
                }
                dotButton
                Divider().frame(height: 36)
                ForEach(0..<ScoreViewModel.layerCount, id: \.self) { i in
                    layerButton(i)
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

    // MARK: - Key signature row

    private var keyRow: some View {
        let key = vm.score.keySignature
        return HStack(spacing: 8) {
            Text("조표")
                .font(.caption.weight(.semibold)).foregroundColor(.secondary)

            // Add a flat / remove a sharp.
            keyStepButton("♭", to: key - 1, enabled: key > -7)

            // Current key, e.g. "다장조" or "G ♯1" / "B♭ ♭2".
            Text(key == 0 ? "다장조"
                          : "\(KeySignature(count: key).tonic) \(KeySignature(count: key).shortLabel)")
                .font(.subheadline.weight(.bold).monospaced())
                .foregroundColor(key == 0 ? .secondary : .accentColor)
                .frame(minWidth: 86)
                .animation(.easeOut(duration: 0.15), value: key)

            // Add a sharp / remove a flat.
            keyStepButton("♯", to: key + 1, enabled: key < 7)

            // Back to C major in one tap (only when there's something to clear).
            if key != 0 {
                Button { vm.setKeySignature(0) } label: {
                    Text("♮")
                        .font(.title3.weight(.bold))
                        .frame(width: 38, height: 36)
                        .background(Color(.systemGray6)).cornerRadius(10)
                        .foregroundColor(.primary)
                }
                .transition(.scale.combined(with: .opacity))
            }

            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.15), value: key)
    }

    /// One side of the key stepper. Moves the signature toward sharps or flats,
    /// clamped to ±7; disabled (greyed) at the ends.
    private func keyStepButton(_ symbol: String, to target: Int, enabled: Bool) -> some View {
        Button { vm.setKeySignature(target) } label: {
            Text(symbol)
                .font(.title3.weight(.bold))
                .frame(width: 44, height: 36)
                .background(Color(.systemGray6)).cornerRadius(10)
                .foregroundColor(.primary)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    /// One duration value button. Selecting it sets the default for new notes
    /// and retunes the current selection to match.
    private func durationButton(_ dur: NoteDuration) -> some View {
        Button {
            vm.selectedDuration = dur
            if let id = vm.selectedNoteID {
                vm.changeDuration(of: id, to: dur)
            }
        } label: {
            // Unicode Musical Symbols (U+1D1xx) aren't in the system font, so we
            // draw the note glyphs ourselves to guarantee they render anywhere.
            let on = vm.selectedDuration == dur
            NoteDurationGlyph(duration: dur)
                .frame(width: 44, height: 44)
                .background(on ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(on ? Color.accentColor : .clear, lineWidth: 2))
                .cornerRadius(10)
                .foregroundColor(.primary)
        }
    }

    /// Dot toggle — newly placed notes get 1.5× length; also dots the current
    /// selection so it tracks the duration buttons.
    private var dotButton: some View {
        Button {
            vm.selectedDotted.toggle()
            if let id = vm.selectedNoteID {
                vm.setDotted(of: id, vm.selectedDotted)
            }
        } label: {
            let on = vm.selectedDotted
            Text("\u{2022}")
                .font(.system(size: 30, weight: .black))
                .frame(width: 44, height: 44)
                .background(on ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(on ? Color.accentColor : .clear, lineWidth: 2))
                .cornerRadius(10)
                .foregroundColor(.primary)
        }
    }

    /// Voice (layer) selector. New notes go into the chosen voice; the dot is
    /// in that voice's color so it matches the noteheads on the staff.
    private func layerButton(_ i: Int) -> some View {
        Button { vm.activeLayer = i } label: {
            let on = vm.activeLayer == i
            VStack(spacing: 2) {
                Circle().fill(noteLayerColor(i)).frame(width: 12, height: 12)
                Text("\(i + 1)").font(.caption2.weight(.bold))
            }
            .frame(width: 44, height: 44)
            .background(on ? Color.accentColor.opacity(0.2) : Color(.systemGray6))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(on ? Color.accentColor : .clear, lineWidth: 2))
            .cornerRadius(10)
            .foregroundColor(.primary)
        }
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
