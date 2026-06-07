//
//  ContentView.swift
//  StaffSinger
//
//  The staff is the full-screen canvas. The play button always floats at the
//  top-right; everything else (title, metronome, settings, and the note-tool
//  panel) is editing chrome that can be pulled down out of the way and brought
//  back with the grabber at the bottom.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var audio: AudioEngine
    @StateObject private var vm: ScoreViewModel

    /// When false, the note-tools panel (and its chrome) is fully hidden and
    /// only the play + tools buttons show. Starts hidden for a clean sheet.
    @State private var showControls = false
    @State private var showSettings = false

    private var panelSpring: Animation { .spring(response: 0.35, dampingFraction: 0.85) }

    init() {
        // Create one engine and share it between the view and the view model
        // so playback toggles and the score editor act on the same object.
        let engine = AudioEngine()
        _audio = StateObject(wrappedValue: engine)
        _vm = StateObject(wrappedValue: ScoreViewModel(audio: engine))
    }

    var body: some View {
        ZStack {
            // Staff + controls stay inside the safe area so nothing tucks under
            // the Dynamic Island / camera or the home indicator.
            StaffView(vm: vm, audio: audio)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomArea
            }
        }
        // Paper color is applied as a background so it bleeds edge-to-edge
        // WITHOUT pulling the content out of the safe area.
        .background(
            Color(red: 0.99, green: 0.98, blue: 0.95).ignoresSafeArea()
        )
        .sheet(isPresented: $showSettings) {
            SettingsSheet(vm: vm, audio: audio)
        }
    }

    // MARK: - Top bar

    /// On a fresh, empty score we show nothing but the staff. The controls
    /// appear once there's something to play / edit.
    private var controlsVisible: Bool {
        !vm.score.notes.isEmpty || showControls
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            if showControls {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.score.title)
                        .font(.headline).lineLimit(1)
                    Text("\(Int(vm.score.tempo)) BPM · \(vm.score.beatsPerMeasure)/\(vm.score.beatUnit)")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 6)
                .transition(.opacity)
            }

            Spacer(minLength: 0)

            if controlsVisible {
                if showControls {
                    circleButton(
                        systemImage: "metronome",
                        tint: audio.metronomeEnabled ? .accentColor : .secondary
                    ) { audio.metronomeEnabled.toggle() }
                        .transition(.scale.combined(with: .opacity))

                    circleButton(systemImage: "slider.horizontal.3", tint: .primary) {
                        showSettings = true
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                // Show / hide the note-tools panel.
                circleButton(
                    systemImage: showControls ? "chevron.down" : "music.note",
                    tint: showControls ? .accentColor : .primary
                ) {
                    withAnimation(panelSpring) { showControls.toggle() }
                }
                .transition(.scale.combined(with: .opacity))

                // Play / stop.
                Button {
                    if audio.isPlaying { vm.stop() } else { vm.play() }
                } label: {
                    Image(systemName: audio.isPlaying ? "stop.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                        .background(audio.isPlaying ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    private func circleButton(systemImage: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.black.opacity(0.05), lineWidth: 1))
        }
    }

    // MARK: - Bottom area (note-tool panel ⇄ slim grabber)

    @ViewBuilder
    private var bottomArea: some View {
        if showControls {
            editorPanel
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        // When hidden the bottom is intentionally empty — open it with the
        // note-tools button at the top-right.
    }

    private var editorPanel: some View {
        VStack(spacing: 0) {
            grabber
            selectionStrip
            Divider()
            EditorToolbar(vm: vm, audio: audio)
        }
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        // Capture taps anywhere on the panel so empty gaps don't fall through
        // to the staff behind it (which would add stray notes).
        .contentShape(Rectangle())
        .onTapGesture { /* swallow */ }
    }

    /// Handle at the top of the panel — drag it down (or tap) to hide.
    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        if value.translation.height > 8 || abs(value.translation.height) < 6 {
                            withAnimation(panelSpring) { showControls = false }
                        }
                    }
            )
    }

    // MARK: - Selected-note read-out

    private var selectionStrip: some View {
        HStack(spacing: 10) {
            if let n = vm.selectedNote, !n.isRest {
                Text(n.pitch.label)
                    .font(.title3.bold().monospaced())
                Text(n.pitch.solfege)
                    .font(.headline).foregroundColor(.accentColor)
                Text(n.duration.displayName)
                    .font(.subheadline).foregroundColor(.secondary)
            } else if vm.chordMode {
                Label("화음 모드: 선택한 음 위에 쌓입니다", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline).foregroundColor(.indigo)
            } else {
                Text("오선을 길게 눌러 음을 고르고 떼면 추가됩니다")
                    .font(.subheadline).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

#Preview {
    ContentView()
}
