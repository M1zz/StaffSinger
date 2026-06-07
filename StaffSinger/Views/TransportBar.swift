//
//  TransportBar.swift
//  StaffSinger
//
//  Top bar: the big play/stop button plus the controls that matter for
//  the "hear the rhythm correctly" use-case — tempo, time signature,
//  metronome and count-in.
//

import SwiftUI

struct TransportBar: View {
    @ObservedObject var vm: ScoreViewModel
    @ObservedObject var audio: AudioEngine
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if audio.isPlaying { vm.stop() } else { vm.play() }
            } label: {
                Image(systemName: audio.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(audio.isPlaying ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.score.title)
                    .font(.headline).lineLimit(1)
                Text("\(Int(vm.score.tempo)) BPM · \(vm.score.beatsPerMeasure)/\(vm.score.beatUnit)")
                    .font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            // Quick metronome toggle.
            Button { audio.metronomeEnabled.toggle() } label: {
                Image(systemName: "metronome")
                    .font(.title3)
                    .foregroundColor(audio.metronomeEnabled ? .accentColor : .secondary)
                    .frame(width: 40, height: 40)
            }

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(vm: vm, audio: audio)
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var vm: ScoreViewModel
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    private let signatures: [(Int, Int)] = [(4,4),(3,4),(2,4),(6,8),(2,2),(3,8)]

    var body: some View {
        NavigationStack {
            Form {
                Section("템포") {
                    HStack {
                        Text("\(Int(vm.score.tempo)) BPM")
                            .monospacedDigit().frame(width: 90, alignment: .leading)
                        Slider(value: Binding(
                            get: { vm.score.tempo },
                            set: { vm.setTempo($0) }), in: 40...200, step: 1)
                    }
                }

                Section("박자표") {
                    Picker("박자", selection: Binding(
                        get: { "\(vm.score.beatsPerMeasure)/\(vm.score.beatUnit)" },
                        set: { sel in
                            let parts = sel.split(separator: "/")
                            if parts.count == 2,
                               let b = Int(parts[0]), let u = Int(parts[1]) {
                                vm.setTimeSignature(beats: b, unit: u)
                            }
                        })) {
                        ForEach(signatures, id: \.0.hashValue) { sig in
                            Text("\(sig.0)/\(sig.1)").tag("\(sig.0)/\(sig.1)")
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("조표 (Key)") {
                    Picker("조표", selection: Binding(
                        get: { vm.score.keySignature },
                        set: { vm.setKeySignature($0) })) {
                        // Flats (♭7…♭1), C major, then sharps (♯1…♯7).
                        ForEach(Array((-7...7).reversed()), id: \.self) { c in
                            Text(KeySignature(count: c).label).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("재생 도우미") {
                    Toggle("메트로놈 (박자 클릭)", isOn: $audio.metronomeEnabled)
                    Toggle("카운트인 (시작 전 한 마디)", isOn: $audio.countInEnabled)
                }

                Section("악보 제목") {
                    TextField("제목", text: $vm.score.title)
                }

                Section {
                    Button(role: .destructive) {
                        vm.clearAll()
                    } label: {
                        Label("전체 지우기", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
