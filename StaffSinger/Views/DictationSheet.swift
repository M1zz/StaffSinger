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
import LeeoKit

struct DictationSheet: View {
    @ObservedObject var dictation: SolfegeDictation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Tempo / time signature the take is counted and quantized against.
    let score: Score
    let onImport: ([ScoreNote]) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 20) {
                takeColumn
                Divider()
                // Longer languages (German, Greek…) run past the screen height;
                // scrolling keeps the column below the toolbar instead of
                // pushing the whole sheet up under it.
                ScrollView { settingsColumn }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: 300)
            }
            .padding(20)
            .navigationTitle("계이름 받아쓰기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", systemImage: "xmark") {
                        dictation.cancel()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("악보에 넣기", systemImage: "square.and.arrow.down") { onImport(dictation.notes) }
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
            example

        case let .countIn(beatsLeft):
            VStack(spacing: 6) {
                Text("\(beatsLeft)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
                    .contentTransition(.numericText())
                Text("준비").font(.subheadline).foregroundColor(.secondary)
            }
            .frame(height: 110)
            .accessibilityElement(children: .combine)

        case let .recording(beat):
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundColor(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                Text("\(measureLabel(for: beat)) · 듣는 중")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            .frame(height: 110)

        case let .done(count):
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundColor(.green)
                    .accessibilityHidden(true)
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
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 110)
        }
    }

    /// Before the first take: a short score with the words to say written
    /// under it. Telling someone to "say the note names on the beat" doesn't
    /// land until they see one measure read out.
    private var example: some View {
        VStack(spacing: 6) {
            Text("메트로놈 네 박을 세고 나면, 박에 맞춰 계이름을 말하세요.")
                .font(.subheadline).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                Text("이 악보는 이렇게 읽어요", comment: "Heading above the worked example in solfège dictation")
                    .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ExampleScore()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("박마다 한 음씩, 8분음표 둘은 한 박에 두 번 말해요. 긴 음은 한 번만 말하고, 쉬는 곳은 \"쉼\"이라고 말해요.",
                 comment: "How to read the worked example aloud in solfège dictation")
                .font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                            Text(note.isRest ? String(localized: "쉼", comment: "A rest in the dictated-notes strip") : note.pitch.label)
                                .font(.subheadline.weight(.semibold))
                            Text(note.durationLabel)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel((note.isRest ? String(localized: "쉼표") : note.pitch.accessibilityLabel)
                                            + ", " + note.durationLabel)
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
            // 응원 부탁 — 목소리로 음표를 꽤 받아써 온 사람에게, 드물게. 받아쓰기를 하는 동안에는 서지 않는다.
            // 이미 Pro 를 가진 사람에게만 부탁한다. 체험 중인 사람에게는 Pro 가 먼저다.
            if case .idle = dictation.phase, ProAccess.shared.hasPro {
                LeeoTipAskSlot<StaffSingerSpec>(tipJar: StaffSingerTip.tipJar,
                                                reached: StaffSingerTipMoments.reachedNow)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("리듬 스냅").font(.subheadline.weight(.semibold))
                Picker("리듬 스냅", selection: $dictation.grid) {
                    ForEach(SpokenSolfege.Grid.allCases) { grid in
                        Text(grid.label).tag(grid)
                    }
                }
                .pickerStyle(.segmented)
                Text(dictation.grid == .free
                     ? String(localized: "말한 순서만 씁니다. 길이는 모두 4분음표로 넣고 나중에 고치세요.")
                     : String(localized: "말한 시점을 가장 가까운 \(dictation.grid.label)음표 자리로 맞춥니다."))
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
                     ? String(localized: "앞 음과 가까운 옥타브를 고릅니다. \"시 도\"가 반음 위로 올라갑니다.")
                     : String(localized: "모든 음이 시작 옥타브에 들어갑니다."))
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

    private func tip(_ text: LocalizedStringKey) -> some View {
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
        return String(localized: "\(measure)마디 \(inMeasure)박")
    }
}

// MARK: - Worked example

/// One measure — 도 레 | 미파 | 솔 — with the word to say under each note and
/// the beat it falls on under that. Drawn by hand: it is five notes that never
/// change, so it needn't carry the editor's staff along.
private struct ExampleScore: View {
    /// (steps above the bottom line E4, beat it starts on, where it sits across
    /// the width). Spaced like print, not by the clock: the two eighths get
    /// room for their words instead of half a beat's worth.
    private static let notes: [(step: Int, beat: Double, at: CGFloat)] =
        [(-2, 0, 0.08), (-1, 1, 0.3), (0, 2, 0.52), (1, 2.5, 0.72), (2, 3, 0.92)]
    /// What to say — the app listens for 도레미 in Korean and "do re mi" elsewhere.
    private static let words = ScoreTextFormat.usesKoreanNotation
        ? ["도", "레", "미", "파", "솔"] : ["do", "re", "mi", "fa", "sol"]

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 9, top: CGFloat = 14, bottom = top + gap * 4
            let left: CGFloat = 46, room = size.width - left - 8
            let ink = GraphicsContext.Shading.color(.primary)

            var lines = Path()
            for i in 0..<5 {
                lines.move(to: CGPoint(x: 0, y: top + gap * CGFloat(i)))
                lines.addLine(to: CGPoint(x: size.width, y: top + gap * CGFloat(i)))
            }
            lines.move(to: CGPoint(x: size.width - 0.5, y: top))
            lines.addLine(to: CGPoint(x: size.width - 0.5, y: bottom))
            ctx.stroke(lines, with: .color(.primary.opacity(0.55)), lineWidth: 1)
            ctx.draw(Text(verbatim: "𝄞").font(.system(size: 54)), at: CGPoint(x: 18, y: top + gap * 2 + 1))

            var stemTops: [CGPoint] = []
            for (index, note) in Self.notes.enumerated() {
                let x = left + room * note.at
                let y = bottom - CGFloat(note.step) * gap / 2
                if note.step <= -2 {   // 도 sits on its own short line below the staff
                    var ledger = Path()
                    ledger.move(to: CGPoint(x: x - 11, y: y)); ledger.addLine(to: CGPoint(x: x + 11, y: y))
                    ctx.stroke(ledger, with: .color(.primary.opacity(0.55)), lineWidth: 1)
                }
                var head = ctx
                head.translateBy(x: x, y: y)
                head.rotate(by: .degrees(-20))
                head.fill(Path(ellipseIn: CGRect(x: -6.2, y: -4.3, width: 12.4, height: 8.6)), with: ink)
                let stemTop = CGPoint(x: x + 5.4, y: y - 28)
                var stem = Path()
                stem.move(to: CGPoint(x: x + 5.4, y: y - 1.5)); stem.addLine(to: stemTop)
                ctx.stroke(stem, with: ink, lineWidth: 1.4)
                stemTops.append(stemTop)

                ctx.draw(Text(verbatim: Self.words[index]).font(.subheadline.weight(.bold))
                            .foregroundColor(.accentColor),
                         at: CGPoint(x: x, y: bottom + 30))
                if note.beat == note.beat.rounded() {
                    ctx.draw(Text(verbatim: "\(Int(note.beat) + 1)").font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: x, y: bottom + 49))
                }
            }
            // 미 · 파 share a beat: two eighths under one beam.
            var beam = Path()
            beam.move(to: stemTops[2]); beam.addLine(to: stemTops[3])
            ctx.stroke(beam, with: ink, style: StrokeStyle(lineWidth: 4.5, lineCap: .butt))
        }
        .frame(height: 110)
        .accessibilityElement()
        .accessibilityLabel(Self.words.joined(separator: " "))
    }
}
