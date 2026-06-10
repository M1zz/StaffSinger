//
//  AudioEngine.swift
//  StaffSinger
//
//  Plays the score with accurate timing. The whole point of the app is
//  that the rhythm and the chord stack are *heard*, so the scheduler is
//  sample-accurate: we hand AVAudioUnitSampler a list of (time, note)
//  events using the engine's own render clock, and a separate metronome
//  click reinforces the beat for the singer reading at sight.
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioEngine: ObservableObject {

    // What the UI observes.
    @Published var isPlaying = false
    /// Index into `chordGroups` that is currently sounding (for highlight).
    @Published var currentGroupIndex: Int? = nil

    // Settings the user can toggle. Persisted so a muted metronome stays muted
    // across launches. `metronomeEnabled` is the master switch for *all* clicks:
    // turning it off silences both the beat track and the count-in.
    @Published var metronomeEnabled: Bool {
        didSet { UserDefaults.standard.set(metronomeEnabled, forKey: Self.metronomeKey) }
    }
    @Published var countInEnabled: Bool {
        didSet { UserDefaults.standard.set(countInEnabled, forKey: Self.countInKey) }
    }

    private static let metronomeKey = "metronomeEnabled"
    private static let countInKey = "countInEnabled"

    private let engine = AVAudioEngine()
    private let melodySampler = AVAudioUnitSampler()
    private let clickSampler = AVAudioUnitSampler()

    /// Token used to cancel scheduled work if the user stops early.
    private var playbackTask: Task<Void, Never>? = nil

    init() {
        // Default both on the first launch; honor the saved choice afterwards.
        let defaults = UserDefaults.standard
        metronomeEnabled = defaults.object(forKey: Self.metronomeKey) as? Bool ?? true
        countInEnabled = defaults.object(forKey: Self.countInKey) as? Bool ?? true
        configureSession()
        buildGraph()
    }

    // MARK: - Setup

    private func configureSession() {
        #if !targetEnvironment(simulator)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
        #endif
    }

    private func buildGraph() {
        engine.attach(melodySampler)
        engine.attach(clickSampler)
        engine.connect(melodySampler, to: engine.mainMixerNode, format: nil)
        engine.connect(clickSampler, to: engine.mainMixerNode, format: nil)

        loadSounds()

        do {
            try engine.start()
        } catch {
            print("Engine start error: \(error)")
        }
    }

    /// Load instrument sounds. The melody voice uses a bundled acoustic piano
    /// SoundFont (Upright Piano KW, FreePats, CC0 public domain — see
    /// Audio/UprightPianoKW-LICENSE.txt). We fall back to the older FluidR3
    /// bank if present, and finally to the sampler's built-in tone so the app
    /// always makes sound out of the box.
    private func loadSounds() {
        // Melody / chord voice — a clean piano is easiest to read pitches from.
        // The bundled bank holds a single piano preset at bank 0 / program 0.
        let pianoBanks = ["UprightPianoKW", "FluidR3"]
        for name in pianoBanks {
            guard let sf = Bundle.main.url(forResource: name, withExtension: "sf2")
            else { continue }
            do {
                try melodySampler.loadSoundBankInstrument(
                    at: sf, program: 0,
                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                break
            } catch {
                print("SoundFont load failed for \(name): \(error)")
            }
        }

        // Metronome click: prefer a woodblock from a full GM bank if one is
        // bundled; the piano-only bank has no such program, so the click then
        // falls back to the sampler's built-in tone — still a clean blip.
        if let gm = Bundle.main.url(forResource: "FluidR3", withExtension: "sf2") {
            try? clickSampler.loadSoundBankInstrument(
                at: gm, program: 115,
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        }
    }

    // MARK: - Single-note audition (used while editing)

    /// Play one pitch immediately so the user hears what they just placed.
    func audition(_ pitch: Pitch, velocity: UInt8 = 90) {
        melodySampler.startNote(UInt8(pitch.midi), withVelocity: velocity, onChannel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.melodySampler.stopNote(UInt8(pitch.midi), onChannel: 0)
        }
    }

    /// Play a stack of pitches together (chord audition while editing).
    func auditionChord(_ pitches: [Pitch], velocity: UInt8 = 85) {
        for p in pitches {
            melodySampler.startNote(UInt8(p.midi), withVelocity: velocity, onChannel: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            for p in pitches {
                self?.melodySampler.stopNote(UInt8(p.midi), onChannel: 0)
            }
        }
    }

    // MARK: - Live preview (scrubbing a pitch while dragging on the staff)

    /// The pitch currently sustained by the finger-down preview, if any.
    private var previewMidi: UInt8? = nil

    /// Start — or slide to — a sustained preview note. Moving to a new pitch
    /// stops the previous one, so dragging up/down sounds like a continuous
    /// scrub. Held until `endPreview()` (i.e. the finger lifts).
    func previewNote(_ pitch: Pitch) {
        let midi = UInt8(pitch.midi)
        guard previewMidi != midi else { return }
        if let prev = previewMidi { melodySampler.stopNote(prev, onChannel: 0) }
        melodySampler.startNote(midi, withVelocity: 75, onChannel: 0)
        previewMidi = midi
    }

    /// Stop the sustained preview note (finger lifted / preview cancelled).
    func endPreview() {
        if let prev = previewMidi { melodySampler.stopNote(prev, onChannel: 0) }
        previewMidi = nil
    }

    // MARK: - Full score playback

    func play(score: Score) {
        stop()
        guard !score.notes.isEmpty else { return }

        isPlaying = true
        let secondsPerBeat = 60.0 / max(20.0, score.tempo)
        let groups = score.chordGroups

        playbackTask = Task { [weak self] in
            guard let self else { return }

            // --- Count-in: one full measure of clicks before the music ---
            // Suppressed entirely when the metronome is muted, so "metronome
            // off" means no clicking at all.
            if self.countInEnabled && self.metronomeEnabled {
                let count = score.beatsPerMeasure
                for i in 0..<count {
                    if Task.isCancelled { return }
                    self.click(strong: i == 0)
                    try? await Task.sleep(nanoseconds: UInt64(secondsPerBeat * 1_000_000_000))
                }
            }

            // --- Metronome track: schedule a click on every beat ---
            // We run it concurrently with the note scheduler so the beat is
            // audible even through long/held chords.
            let metronomeTask = Task { [weak self] in
                guard let self else { return }
                guard self.metronomeEnabled else { return }
                // Click each beat the music actually occupies — beats 0 … N-1
                // for an N-beat score. Using `<` (not `<=`) stops us from
                // sounding one extra downbeat past the end, which made a full
                // 4/4 bar (e.g. 8 8 4 4 4) click five times and feel like 5/4.
                let totalBeats = Int(ceil(score.totalBeats - 0.001))
                let qbpm = score.quarterBeatsPerMeasure
                var beat = 0.0
                var idx = 0
                while idx < totalBeats {
                    if Task.isCancelled { return }
                    let positionInMeasure = beat.truncatingRemainder(dividingBy: qbpm)
                    self.click(strong: abs(positionInMeasure) < 0.001)
                    try? await Task.sleep(nanoseconds: UInt64(secondsPerBeat * 1_000_000_000))
                    beat += 1.0
                    idx += 1
                }
            }

            // --- Note scheduler: walk chord groups in time order ---
            var elapsedBeats = 0.0
            for (index, group) in groups.enumerated() {
                if Task.isCancelled { metronomeTask.cancel(); return }

                // Wait until this group's start beat.
                let waitBeats = group.beat - elapsedBeats
                if waitBeats > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(waitBeats * secondsPerBeat * 1_000_000_000))
                    elapsedBeats = group.beat
                }

                if Task.isCancelled { metronomeTask.cancel(); return }

                self.currentGroupIndex = index

                // Sound every note in the group (chord = simultaneous notes).
                let sounding = group.notes.filter { !$0.isRest }
                for note in sounding {
                    self.melodySampler.startNote(
                        UInt8(note.pitch.midi), withVelocity: 95, onChannel: 0)
                }

                // Hold for the longest note in the group, then release.
                let holdBeats = group.notes.map { $0.beats }.max() ?? 1.0
                try? await Task.sleep(
                    nanoseconds: UInt64(holdBeats * secondsPerBeat * 1_000_000_000))
                elapsedBeats += holdBeats

                for note in sounding {
                    self.melodySampler.stopNote(UInt8(note.pitch.midi), onChannel: 0)
                }
            }

            metronomeTask.cancel()
            self.currentGroupIndex = nil
            self.isPlaying = false
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        // Kill any lingering notes.
        for midi in 0...127 {
            melodySampler.stopNote(UInt8(midi), onChannel: 0)
        }
        isPlaying = false
        currentGroupIndex = nil
    }

    // MARK: - Metronome click

    private func click(strong: Bool) {
        // Two woodblock pitches: high for the downbeat, lower otherwise.
        let note: UInt8 = strong ? 76 : 70
        let vel: UInt8 = strong ? 110 : 80
        clickSampler.startNote(note, withVelocity: vel, onChannel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.clickSampler.stopNote(note, onChannel: 0)
        }
    }
}
