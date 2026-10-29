//
//  PitchListener.swift
//  StaffSinger
//
//  "Hum the note and it lands."
//
//  While a button is held, the mic listens and reports the pitch being sung;
//  on release it hands back the pitch held most steadily. Everything happens
//  on the device: frames go through the YIN pitch detector and are dropped —
//  nothing is recorded or sent anywhere.
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class PitchListener: ObservableObject {

    /// The pitch heard right now (MIDI), nil while silent or unclear.
    @Published private(set) var heardMidi: Int? = nil
    @Published private(set) var isListening = false

    private let audio: AudioEngine
    private let engine = AVAudioEngine()
    /// Recent readings; the answer is the one heard most often (≈ half a second).
    private var recent: [Int] = []
    /// False once the button is let go — a release during the permission
    /// prompt must not leave the mic open.
    private var wanted = false

    init(audio: AudioEngine) {
        self.audio = audio
    }

    /// Start listening. Returns false when the mic can't be used.
    @discardableResult
    func start() async -> Bool {
        guard !isListening else { return true }
        wanted = true
        guard await AVAudioApplication.requestRecordPermission(), wanted else { return false }

        audio.beginRecordingSession()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { audio.endRecordingSession(); return false }
        let rate = format.sampleRate

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let window = min(count, 2048)   // enough for a 65 Hz period, cheap to scan
            let samples = Array(UnsafeBufferPointer(start: channel + (count - window), count: window))
            let freq = PitchDetector.frequency(of: samples, sampleRate: rate)
            Task { @MainActor in self?.hear(freq) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardown()
            return false
        }
        recent = []
        isListening = true
        return true
    }

    /// Stop and return the pitch held most steadily (MIDI), if any.
    func stop() -> Int? {
        wanted = false
        guard isListening else { return nil }
        teardown()
        let counts = Dictionary(recent.map { ($0, 1) }, uniquingKeysWith: +)
        recent = []
        heardMidi = nil
        return counts.max { $0.value < $1.value }?.key
    }

    private func hear(_ freq: Double?) {
        guard isListening else { return }
        guard let freq else { heardMidi = nil; return }
        let midi = Int((69 + 12 * log2(freq / 440)).rounded())
        recent.append(midi)
        if recent.count > 12 { recent.removeFirst() }
        heardMidi = midi
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        isListening = false
        audio.endRecordingSession()
    }
}

// MARK: - YIN

/// Fundamental frequency of a short mono frame, by YIN (de Cheveigné &
/// Kawahara, 2002). Returns nil for silence, noise, or anything without a
/// clear period in the singing range.
enum PitchDetector {

    static func frequency(of x: [Float], sampleRate: Double,
                          range: ClosedRange<Double> = 65...1100) -> Double? {
        let n = x.count
        guard n > 0 else { return nil }
        let rms = sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(n))
        guard rms > 0.01 else { return nil }                 // silence

        let minTau = max(2, Int(sampleRate / range.upperBound))
        let maxTau = min(n / 2, Int(sampleRate / range.lowerBound))
        guard maxTau > minTau + 1 else { return nil }
        let width = n - maxTau

        // Cumulative-mean-normalized difference function.
        var cmnd = [Float](repeating: 1, count: maxTau + 2)
        x.withUnsafeBufferPointer { p in
            var running: Float = 0
            for tau in 1...maxTau {
                var sum: Float = 0
                for j in 0..<width {
                    let diff = p[j] - p[j + tau]
                    sum += diff * diff
                }
                running += sum
                cmnd[tau] = running > 0 ? sum * Float(tau) / running : 1
            }
        }

        // First dip under the threshold, followed down to its bottom.
        var tau = minTau
        while tau <= maxTau, cmnd[tau] >= 0.15 { tau += 1 }
        guard tau <= maxTau else { return nil }              // no clear period
        while tau < maxTau, cmnd[tau + 1] < cmnd[tau] { tau += 1 }

        // Parabolic interpolation for a finer period.
        let a = cmnd[tau - 1], b = cmnd[tau], c = cmnd[tau + 1]
        let bend = a + c - 2 * b
        let period = Double(tau) + (abs(bend) > 1e-9 ? Double((a - c) / (2 * bend)) : 0)
        return sampleRate / period
    }
}
