//
//  SolfegeDictation.swift
//  StaffSinger
//
//  "Read the score out loud and it lands on the staff."
//
//  One take covers both halves of note entry: the syllable says which note,
//  and the moment it was spoken says where the beat is. So the flow mirrors
//  playback rather than inventing a new one — a count-in measure of clicks,
//  then two measures to speak over, then auto-stop. `SpokenSolfege` does the
//  quantizing; this object only has to produce accurately timed words.
//
//  Timing accuracy comes from counting frames delivered to the mic tap rather
//  than reading the wall clock: `SFTranscriptionSegment.timestamp` is measured
//  from the start of the audio fed to the recognizer, so the two only line up
//  if we measure the count-in in that same audio timeline. Frame counting is
//  drift-free and costs one addition per buffer.
//
//  Recognition is pinned to ON-DEVICE. The app ships a privacy policy saying
//  nothing leaves the phone, and the server path would send recorded audio to
//  Apple — so if a device can't do it locally, dictation reports that and
//  refuses rather than quietly going online.
//

import Foundation
import AVFoundation
import Speech
import Combine

@MainActor
final class SolfegeDictation: ObservableObject {

    // MARK: - State

    enum Phase: Equatable {
        case idle
        /// Clicking down the count-in; `beatsLeft` drives the big number.
        case countIn(beatsLeft: Int)
        /// Listening. `beat` is the position within the two measures.
        case recording(beat: Double)
        /// Recognition finished and produced notes.
        case done(noteCount: Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Words heard so far, shown live so the user can see it is working.
    @Published private(set) var heard: String = ""
    /// The take's result, ready to be dropped on the staff.
    @Published private(set) var notes: [ScoreNote] = []

    /// Snap resolution for spoken timing. Persisted — a user who reads in
    /// eighths keeps reading in eighths.
    @Published var grid: SpokenSolfege.Grid = {
        let raw = UserDefaults.standard.double(forKey: gridKey)
        return SpokenSolfege.Grid(rawValue: raw) ?? .eighth
    }() {
        didSet { UserDefaults.standard.set(grid.rawValue, forKey: Self.gridKey) }
    }
    /// Octave the first spoken note lands in.
    @Published var baseOctave: Int = {
        let saved = UserDefaults.standard.object(forKey: octaveKey) as? Int
        return saved ?? 4
    }() {
        didSet { UserDefaults.standard.set(baseOctave, forKey: Self.octaveKey) }
    }
    /// Let later notes pick the nearest octave (so 시→도 rises a semitone).
    @Published var autoOctave: Bool = {
        UserDefaults.standard.object(forKey: autoOctaveKey) as? Bool ?? true
    }() {
        didSet { UserDefaults.standard.set(autoOctave, forKey: Self.autoOctaveKey) }
    }

    private static let gridKey = "dictation.grid"
    private static let octaveKey = "dictation.baseOctave"
    private static let autoOctaveKey = "dictation.autoOctave"

    var isBusy: Bool {
        switch phase {
        case .countIn, .recording: return true
        default: return false
        }
    }

    // MARK: - Machinery

    private let audio: AudioEngine
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var runTask: Task<Void, Never>?

    /// Frames handed to the tap so far — our clock in the recognizer's own
    /// timeline. Touched from the audio thread, read on the main actor after
    /// the tap is removed, so it is guarded by a lock.
    private let framesLock = NSLock()
    private var framesSeen: AVAudioFramePosition = 0
    private var tapSampleRate: Double = 44_100

    /// Audio-timeline second at which the count-in ended (beat 0 of the music).
    private var musicStartTime: Double = 0
    /// Beats the take is allowed to run for (the two visible measures).
    private var capacityBeats: Double = 8
    /// One bar's beats — closes the final note out on a bar line.
    private var measureBeats: Double = 4
    private var tempo: Double = 90

    init(audio: AudioEngine) {
        self.audio = audio
    }

    // MARK: - Permissions

    /// Ask for microphone + speech permission. Returns nil on success or a
    /// user-facing reason on failure.
    private func requestPermissions() async -> String? {
        guard let recognizer, recognizer.isAvailable else {
            return "이 기기에서 한국어 음성 인식을 쓸 수 없습니다."
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return "기기 안에서 처리하는 한국어 음성 인식이 준비되지 않았습니다.\n"
                 + "설정 ▸ 일반 ▸ 키보드 ▸ 받아쓰기에서 한국어를 켜면 필요한 파일이 내려받아집니다."
        }

        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            return "음성 인식 권한이 필요합니다. 설정에서 허용해 주세요."
        }

        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard mic else {
            return "마이크 권한이 필요합니다. 설정에서 허용해 주세요."
        }
        return nil
    }

    // MARK: - Take

    /// Run one take: count-in, listen for two measures, then quantize.
    func start(score: Score) {
        guard !isBusy else { return }
        cancelTask()
        notes = []
        heard = ""
        tempo = score.tempo
        measureBeats = max(1, score.quarterBeatsPerMeasure)
        capacityBeats = measureBeats * 2

        runTask = Task { [weak self] in
            guard let self else { return }
            if let problem = await self.requestPermissions() {
                self.phase = .failed(problem)
                return
            }
            do {
                try await self.run(score: score)
            } catch is CancellationError {
                // An early stop is already being finished elsewhere; only a
                // real abandon (cancel()) should reset the take here.
                if !self.finishingEarly {
                    self.teardown()
                    self.phase = .idle
                }
            } catch {
                self.teardown()
                self.phase = .failed("녹음을 시작할 수 없습니다: \(error.localizedDescription)")
            }
        }
    }

    /// True while `stop()` is winding a take down on purpose. Cancelling
    /// `runTask` makes `run` throw `CancellationError`, and its handler would
    /// otherwise tear the recognizer down before `finish` could read the
    /// result — losing every note the user just spoke.
    private var finishingEarly = false

    /// Stop early and keep whatever has been heard so far.
    func stop() {
        guard isBusy else { return }
        finishingEarly = true
        runTask?.cancel()
        runTask = nil
        Task {
            await finish()
            finishingEarly = false
        }
    }

    /// Abandon the take entirely.
    func cancel() {
        finishingEarly = false
        cancelTask()
        teardown()
        phase = .idle
        heard = ""
        notes = []
    }

    private func cancelTask() {
        runTask?.cancel()
        runTask = nil
    }

    // MARK: - Recording pipeline

    private func run(score: Score) async throws {
        audio.beginRecordingSession()
        try startListening()

        let secondsPerBeat = 60.0 / max(20.0, tempo)
        let nanosPerBeat = UInt64(secondsPerBeat * 1_000_000_000)

        // Count-in: a full measure, using the same click as playback so the
        // tempo the user hears is the tempo we quantize against.
        let countBeats = max(1, score.beatsPerMeasure)
        for i in 0..<countBeats {
            try Task.checkCancellation()
            phase = .countIn(beatsLeft: countBeats - i)
            audio.tick(strong: i == 0)
            try await Task.sleep(nanoseconds: nanosPerBeat)
        }

        // Beat 0 of the music, marked in the recognizer's own audio timeline.
        try Task.checkCancellation()
        musicStartTime = currentAudioTime()

        // Listen for the two visible measures, clicking along.
        let totalBeats = Int(capacityBeats.rounded())
        let barBeats = max(1.0, score.quarterBeatsPerMeasure)
        for i in 0..<totalBeats {
            try Task.checkCancellation()
            phase = .recording(beat: Double(i))
            let position = Double(i).truncatingRemainder(dividingBy: barBeats)
            audio.tick(strong: abs(position) < 0.001)
            try await Task.sleep(nanoseconds: nanosPerBeat)
        }

        // A short tail so the final syllable is fully captured before we cut.
        try await Task.sleep(nanoseconds: UInt64(0.45 * 1_000_000_000))
        try Task.checkCancellation()
        await finish()
    }

    private func startListening() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // keeps the app offline
        request.taskHint = .dictation
        request.contextualStrings = SpokenSolfege.contextualStrings
        if #available(iOS 16.0, *) { request.addsPunctuation = false }
        self.request = request

        framesLock.lock(); framesSeen = 0; framesLock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "SolfegeDictation", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "마이크 입력을 찾지 못했습니다."
            ])
        }
        tapSampleRate = format.sampleRate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.framesLock.lock()
            self.framesSeen += AVAudioFramePosition(buffer.frameLength)
            self.framesLock.unlock()
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.latestResult = result
                    self.heard = result.bestTranscription.formattedString
                }
                if error != nil { self.latestError = error }
            }
        }
    }

    /// Most recent recognition result, kept so the take can be quantized the
    /// moment listening stops (partial results are already good enough — the
    /// final one just arrives with better segment timings).
    private var latestResult: SFSpeechRecognitionResult?
    private var latestError: Error?

    /// Seconds of audio the recognizer has been given so far.
    private func currentAudioTime() -> Double {
        framesLock.lock()
        let frames = framesSeen
        framesLock.unlock()
        return Double(frames) / tapSampleRate
    }

    // MARK: - Finish

    private func finish() async {
        guard request != nil else { return }
        let endTime = currentAudioTime()

        // Close the audio side first, then give the recognizer a beat to emit
        // its final, better-timed transcription before we read it.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        try? await Task.sleep(nanoseconds: 700_000_000)

        task?.finish()
        let result = latestResult
        teardown()

        guard let result, !result.bestTranscription.segments.isEmpty else {
            phase = .failed(latestError == nil
                ? "계이름을 알아듣지 못했습니다. 메트로놈에 맞춰 또박또박 \"도 레 미\"처럼 말해 보세요."
                : "음성 인식에 실패했습니다. 잠시 후 다시 시도해 주세요.")
            return
        }

        let events = self.events(from: result.bestTranscription.segments,
                                 musicEnd: endTime)
        let placed = SpokenSolfege.notes(from: events,
                                         tempo: tempo,
                                         grid: grid,
                                         baseOctave: baseOctave,
                                         autoOctave: autoOctave,
                                         measureBeats: measureBeats,
                                         capacityBeats: capacityBeats)
        notes = placed
        heard = result.bestTranscription.formattedString
        phase = placed.isEmpty
            ? .failed("\"\(heard)\" — 여기서 계이름을 찾지 못했습니다.\n도 레 미 파 솔 라 시 로 말해 주세요.")
            : .done(noteCount: placed.count)
    }

    /// Recognized segments → events timed from the downbeat.
    ///
    /// Segment timestamps are normally populated, but on-device recognition
    /// has been known to report zeros; when that happens the words are spread
    /// evenly across the take so the melody still lands (with even rhythm)
    /// instead of collapsing onto beat 0.
    private func events(from segments: [SFTranscriptionSegment],
                        musicEnd: Double) -> [SpokenEvent] {
        let timed = segments.contains { $0.timestamp > 0 }
        guard timed else {
            let span = max(0.001, musicEnd - musicStartTime)
            let step = span / Double(max(1, segments.count))
            return segments.enumerated().map { index, segment in
                SpokenEvent(word: segment.substring,
                            time: step * Double(index),
                            duration: step)
            }
        }
        return segments.map {
            SpokenEvent(word: $0.substring,
                        time: $0.timestamp - musicStartTime,
                        duration: $0.duration)
        }
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request = nil
        task = nil
        latestResult = nil
        latestError = nil
        audio.endRecordingSession()
    }
}
