//
//  HumButton.swift
//  StaffSinger
//
//  Hold, hum, let go: the steadiest pitch heard is handed to `onPitch`.
//  While held, the button shows the note name it hears, so the singer can
//  slide onto the right note before letting go.
//

import SwiftUI
import UIKit
import AVFoundation

struct HumButton: View {
    @ObservedObject var listener: PitchListener
    /// Spells a heard black key as a flat in flat keys.
    var keySignature: Int = 0
    let onPitch: (Int) -> Void

    @State private var holding = false
    @State private var micDenied = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(listener.isListening ? Color.accentColor : Color.accentColor.opacity(0.12))
            if let midi = listener.heardMidi {
                Text(Pitch(midi: midi, prefersFlat: keySignature < 0).name)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
            } else {
                Image(systemName: listener.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(listener.isListening ? .white : .accentColor)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding else { return }
                    holding = true
                    begin()
                }
                .onEnded { _ in
                    holding = false
                    finish()
                }
        )
        // VoiceOver: activate once to start listening, again to finish.
        .accessibilityElement()
        .accessibilityLabel("누른 채 흥얼거리기")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if listener.isListening { finish() } else { begin() }
        }
        .alert("마이크 권한이 필요합니다. 설정에서 허용해 주세요.", isPresented: $micDenied) {
            Button("확인", role: .cancel) {}
        }
    }

    private func begin() {
        Task {
            if await !listener.start(),
               AVAudioApplication.shared.recordPermission == .denied {
                micDenied = true
            }
        }
    }

    private func finish() {
        guard let midi = listener.stop() else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onPitch(midi)
    }
}
