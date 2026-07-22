//
//  TransportBar.swift
//  StaffSinger
//
//  Top bar: the big play/stop button plus the controls that matter for
//  the "hear the rhythm correctly" use-case — tempo, time signature,
//  metronome and count-in.
//

import SwiftUI
import LeeoKit

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

    var body: some View {
        NavigationStack {
            SettingsForm(vm: vm, audio: audio)
                .navigationTitle("설정")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("완료") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Settings side panel (palette)

/// A slim settings palette that slides in from one edge, leaving the staff
/// visible instead of covering it. The side can flip to the left for
/// left-handed use.
struct SettingsSidePanel: View {
    @ObservedObject var vm: ScoreViewModel
    @ObservedObject var audio: AudioEngine
    @Binding var onLeft: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header: title, left/right side flip, and close.
            HStack(spacing: 12) {
                Text("설정").font(.headline)
                Spacer(minLength: 0)
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { onLeft.toggle() } } label: {
                    Image(systemName: onLeft
                          ? "rectangle.righthalf.inset.filled"
                          : "rectangle.lefthalf.inset.filled")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .accessibilityLabel(onLeft ? "오른쪽에 표시" : "왼쪽에 표시")

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("닫기")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            SettingsForm(vm: vm, audio: audio)
                .scrollContentBackground(.hidden)   // let the panel material show
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

// MARK: - Settings form (shared by the sheet & the side panel)

struct SettingsForm: View {
    @ObservedObject var vm: ScoreViewModel
    @ObservedObject var audio: AudioEngine

    private let signatures: [(Int, Int)] = [(4,4),(3,4),(2,4),(6,8),(2,2),(3,8)]

    var body: some View {
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

                Section("음자리표 (Clef)") {
                    Picker("음자리표", selection: Binding(
                        get: { vm.score.clef },
                        set: { vm.setClef($0) })) {
                        ForEach(Clef.allCases) { c in
                            Text(c.displayName).tag(c)
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

                Section {
                    LeeoSupportSection<StaffSingerSpec>()
                } header: {
                    Text("지원")
                }

                DeveloperContactSection()
            }
    }
}

// MARK: - 개발자 문의
struct DeveloperContactSection: View {
    var body: some View {
        Section {
            Link(destination: URL(string: "mailto:leeo@kakao.com")!) {
                Label("이메일로 문의하기", systemImage: "envelope")
            }
            Link(destination: URL(string: "https://instagram.com/lee25_ios")!) {
                Label("인스타그램 DM (@lee25_ios)", systemImage: "paperplane")
            }
        } header: {
            Text("개발자에게 문의")
        } footer: {
            Text("버그 제보와 기능 제안을 환영합니다.")
        }
    }
}
