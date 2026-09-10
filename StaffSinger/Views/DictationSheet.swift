//
//  DictationSheet.swift
//  StaffSinger
//
//  The face of voice dictation: press once, hear a count-in, read the score
//  out loud, and watch the notes appear. Laid out side by side because the app
//  is landscape-only — the take (status, what was heard, the result) sits on
//  the left where the eye lands, and the settings that change how a take is
//  interpreted stay parked on the right.
//

import SwiftUI

struct DictationSheet: View {
    @ObservedObject var dictation: SolfegeDictation
    /// Tempo / time signature the take is counted and quantized against.
    let score: Score
    let onImport: ([ScoreNote]) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 20) {
                takeColumn
                Divider()
                settingsColumn.frame(width: 300)
            }
            .padding(20)
            .navigationTitle("계이름 받아쓰기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dictation.cancel()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("악보에 넣기") { onImport(dictation.notes) }
                        .fontWeight(.semibold)
                        .disabled(dictation.notes.isEmpty)
                }
            }
        }
        .onDisappear { dictation.cancel() }
    }

    // MARK: - Take

    private var takeColumn: some View {
        VStack(spacing: 16) {
            statusView
            recordButton
            if !dictation.heard.isEmpty {
                heardStrip
            }
            if !dictation.notes.isEmpty {
                resultStrip
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// The big centrepiece: a count-in number while counting, a level-style
    /// beat pulse while listening, and the outcome once the take is over.
    @ViewBuilder
    private var statusView: some View {
        switch dictation.phase {
        case .idle:
            instruction("메트로놈 네 박을 세고 나면, 박에 맞춰 계이름을 말하세요.",
                        detail: "도 레 미 파 솔 라 시 · 쉬는 곳은 \"쉼\"")

        case let .countIn(beatsLeft):
            VStack(spacing: 6) {
                Text("\(beatsLeft)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
                    .contentTransition(.numericText())
                Text("준비").font(.subheadline).foregroundColor(.secondary)
            }
            .frame(height: 110)

        case let .recording(beat):
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundColor(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("\(measureLabel(for: beat)) · 듣는 중")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            .frame(height: 110)

        case let .done(count):
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundColor(.green)
                Text("\(count)개 음표를 받아썼습니다")
                    .font(.headline)
                Text("아래에서 확인하고 \"악보에 넣기\"를 누르세요")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(height: 110)

        case let .failed(message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundColor(.orange)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 110)
        }
    }

    private func instruction(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "music.mic")
                .font(.system(size: 40)).foregroundColor(.accentColor)
            Text(title).font(.subheadline).multilineTextAlignment(.center)
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
        .frame(height: 110)
    }

    private var recordButton: some View {
        Button {
            if dictation.isBusy { dictation.stop() } else { dictation.start(score: score) }
        } label: {
            Label(dictation.isBusy ? "멈추기" : "말하기 시작",
                  systemImage: dictation.isBusy ? "stop.fill" : "mic.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(dictation.isBusy ? Color.red : Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    /// Raw transcript — reassurance that the mic is live, and the first place
    /// to look when a note comes out wrong.
    private var heardStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("들은 말").font(.caption).foregroundColor(.secondary)
            Text(dictation.heard)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// What actually landed: solfege plus the length each syllable's timing
    /// produced, so a wrong rhythm is visible before it hits the staff.
    private var resultStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("악보에 들어갈 음표").font(.caption).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(dictation.notes) { note in
                        VStack(spacing: 1) {
                            Text(note.isRest ? "쉼" : note.pitch.label)
                                .font(.subheadline.weight(.semibold))
                            Text(note.durationLabel)
                                .font(.system(size: 9)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Settings

    private var settingsColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("리듬 스냅").font(.subheadline.weight(.semibold))
                Picker("리듬 스냅", selection: $dictation.grid) {
                    ForEach(SpokenSolfege.Grid.allCases) { grid in
                        Text(grid.label).tag(grid)
                    }
                }
                .pickerStyle(.segmented)
                Text(dictation.grid == .free
                     ? "말한 순서만 씁니다. 길이는 모두 4분음표로 넣고 나중에 고치세요."
                     : "말한 시점을 가장 가까운 \(dictation.grid.label)음표 자리로 맞춥니다.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Stepper("시작 옥타브  \(dictation.baseOctave)옥",
                        value: $dictation.baseOctave, in: 2...6)
                    .font(.subheadline)
                Toggle("옥타브 자동 맞춤", isOn: $dictation.autoOctave)
                    .font(.subheadline)
                Text(dictation.autoOctave
                     ? "앞 음과 가까운 옥타브를 고릅니다. \"시 도\"가 반음 위로 올라갑니다."
                     : "모든 음이 시작 옥타브에 들어갑니다.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("잘 되게 하려면").font(.caption.weight(.semibold))
                tip("이어폰을 쓰면 메트로놈이 마이크에 섞이지 않습니다")
                tip("한 음씩 또박또박, 박에 딱 맞춰 말하세요")
                tip("4도보다 넓게 뛸 땐 \"높은 솔\", \"낮은 시\"처럼 말하세요")
                tip("빠르면 템포를 낮추세요 (현재 \(Int(score.tempo)) BPM)")
            }

            Spacer(minLength: 0)
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("·").font(.caption).foregroundColor(.secondary)
            Text(text).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "1마디 3박" for the beat counter while listening.
    private func measureLabel(for beat: Double) -> String {
        let perMeasure = max(1.0, score.quarterBeatsPerMeasure)
        let measure = Int(beat / perMeasure) + 1
        let inMeasure = Int(beat.truncatingRemainder(dividingBy: perMeasure)) + 1
        return "\(measure)마디 \(inMeasure)박"
    }
}
