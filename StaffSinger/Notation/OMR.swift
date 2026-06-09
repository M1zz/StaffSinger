//
//  OMR.swift
//  StaffSinger
//
//  EXPERIMENTAL optical music recognition. A deliberately small, dependency-free
//  classic-CV pipeline tuned for the easy case: a clean, printed, single-staff,
//  monophonic line (e.g. two measures shot through a fixed aperture). It is NOT
//  a general OMR engine — beams, chords, accidentals, and key signatures are not
//  understood, and pitch/rhythm are best-effort. The user is expected to fix the
//  result by hand afterwards.
//
//  Pipeline: upright → grayscale → Otsu binarize → staff-line detection
//  (horizontal projection) → staff removal → column segmentation into notes →
//  per-note head localization → Y→pitch (treble) + filled/open + stem → duration.
//

import UIKit
import CoreGraphics

enum OMR {

    /// Best-effort transcription. Returns notes left-to-right with cumulative
    /// beats, or an empty array if no staff could be found.
    static func transcribe(_ image: UIImage, maxBeats: Double = 8) -> [ScoreNote] {
        guard let gray = grayscale(upright(image)) else { return [] }
        let ink = binarize(gray)
        guard let staff = detectStaff(ink, width: gray.w, height: gray.h) else { return [] }
        let heads = detectNotes(ink, width: gray.w, height: gray.h, staff: staff)
        return assignBeats(heads, staff: staff, maxBeats: maxBeats)
    }

    // MARK: - Pixels

    private struct Gray { let w: Int; let h: Int; var px: [UInt8] }

    /// Redraw respecting EXIF orientation so the buffer is always upright.
    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let r = UIGraphicsImageRenderer(size: image.size)
        return r.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    /// Downscaled top-left-origin grayscale buffer.
    private static func grayscale(_ image: UIImage, maxWidth: Int = 1200) -> Gray? {
        guard let cg = image.cgImage else { return nil }
        let scale = min(1.0, Double(maxWidth) / Double(max(1, cg.width)))
        let w = max(1, Int(Double(cg.width) * scale))
        let h = max(1, Int(Double(cg.height) * scale))
        var data = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))   // flip so row 0 == top
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Gray(w: w, h: h, px: data)
    }

    /// Otsu threshold → ink mask (true = dark ink).
    private static func binarize(_ g: Gray) -> [Bool] {
        var hist = [Int](repeating: 0, count: 256)
        for v in g.px { hist[Int(v)] += 1 }
        let total = g.px.count
        var sum = 0.0
        for t in 0..<256 { sum += Double(t * hist[t]) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 127
        for t in 0..<256 {
            wB += hist[t]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB)
            let mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return g.px.map { Int($0) < threshold }
    }

    // MARK: - Staff

    private struct Staff { let lineYs: [Int]; let spacing: Double; var topY: Int { lineYs.first ?? 0 } }

    private static func detectStaff(_ ink: [Bool], width w: Int, height h: Int) -> Staff? {
        // Ink per row; staff lines span most of the width.
        var rowInk = [Int](repeating: 0, count: h)
        for y in 0..<h {
            var c = 0
            let base = y * w
            for x in 0..<w where ink[base + x] { c += 1 }
            rowInk[y] = c
        }
        // Cluster qualifying rows into line centers, trying a couple of cutoffs.
        for frac in [0.5, 0.4, 0.3] {
            let cutoff = Int(Double(w) * frac)
            var centers: [Int] = []
            var y = 0
            while y < h {
                if rowInk[y] >= cutoff {
                    var y2 = y
                    while y2 + 1 < h && rowInk[y2 + 1] >= cutoff { y2 += 1 }
                    centers.append((y + y2) / 2)
                    y = y2 + 1
                } else { y += 1 }
            }
            if let staff = pickFiveLines(centers) { return staff }
        }
        return nil
    }

    /// From candidate line rows, choose 5 with the most uniform spacing.
    private static func pickFiveLines(_ centers: [Int]) -> Staff? {
        guard centers.count >= 5 else { return nil }
        let s = centers.sorted()
        var bestStart = 0, bestVar = Double.greatestFiniteMagnitude
        for start in 0...(s.count - 5) {
            let win = Array(s[start..<start + 5])
            let gaps = zip(win.dropFirst(), win).map { Double($0 - $1) }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            guard mean > 1 else { continue }
            let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
            let norm = variance / (mean * mean)   // scale-independent
            if norm < bestVar { bestVar = norm; bestStart = start }
        }
        let win = Array(s[bestStart..<bestStart + 5])
        let gaps = zip(win.dropFirst(), win).map { Double($0 - $1) }
        let spacing = gaps.reduce(0, +) / Double(gaps.count)
        guard spacing > 3, bestVar < 0.15 else { return nil }   // reject if not staff-like
        return Staff(lineYs: win, spacing: spacing)
    }

    // MARK: - Notes

    private struct Head { let centerX: Int; let centerY: Int; let duration: NoteDuration }

    /// Find noteheads WITHOUT removing staff lines: a notehead is a vertically
    /// tall band of "wide ink" (≈ a staff space high), whereas staff lines are
    /// only ~2px tall and stems are too thin to count as wide. Works whether the
    /// head sits on a line or in a space.
    private static func detectNotes(_ ink: [Bool], width w: Int, height h: Int,
                                    staff: Staff) -> [Head] {
        let S = staff.spacing

        // Column ink, and a baseline = typical staff-only column (median of the
        // staff region) so note columns stand out above the five lines.
        var colInk = [Int](repeating: 0, count: w)
        for x in 0..<w {
            var c = 0
            for y in 0..<h where ink[y * w + x] { c += 1 }
            colInk[x] = c
        }
        let nonzero = colInk.filter { $0 > 0 }.sorted()
        let baseline = nonzero.isEmpty ? 0 : nonzero[nonzero.count / 2]
        let colThresh = baseline + max(2, Int(S * 0.3))
        let gapToSplit = max(2, Int(S * 0.6))

        // Segment x into note clusters (monophonic: separated by whitespace).
        var clusters: [(Int, Int)] = []
        var x = 0
        while x < w {
            if colInk[x] >= colThresh {
                var x2 = x, gap = 0
                while x2 + 1 < w {
                    if colInk[x2 + 1] >= colThresh { gap = 0; x2 += 1 }
                    else { gap += 1; if gap > gapToSplit { break }; x2 += 1 }
                }
                clusters.append((x, min(x2, w - 1)))
                x = x2 + 1
            } else { x += 1 }
        }

        var heads: [Head] = []
        let wideRun = max(3, Int(S * 0.55))
        let minBand = max(3, Int(S * 0.5))
        let maxBand = Int(S * 1.8)

        for (x0, x1) in clusters where x1 - x0 + 1 >= Int(S * 0.4) {
            // Longest horizontal ink run per row within the cluster.
            var runByRow = [Int](repeating: 0, count: h)
            for y in 0..<h {
                let base = y * w
                var run = 0, localBest = 0
                for xx in x0...x1 {
                    if ink[base + xx] { run += 1; localBest = max(localBest, run) }
                    else { run = 0 }
                }
                runByRow[y] = localBest
            }

            // Tallest contiguous band of "wide" rows that's notehead-sized.
            var bestTop = -1, bestBot = -1, bestScore = 0
            var y = 0
            while y < h {
                if runByRow[y] >= wideRun {
                    var y2 = y
                    while y2 + 1 < h && runByRow[y2 + 1] >= wideRun { y2 += 1 }
                    let bandH = y2 - y + 1
                    if bandH >= minBand && bandH <= maxBand {
                        let score = (y...y2).reduce(0) { $0 + runByRow[$1] }
                        if score > bestScore { bestScore = score; bestTop = y; bestBot = y2 }
                    }
                    y = y2 + 1
                } else { y += 1 }
            }
            guard bestTop >= 0 else { continue }   // no notehead-shaped band here
            let centerY = (bestTop + bestBot) / 2

            // Filled vs open: ink ratio inside the head band.
            var inkCount = 0, area = 0
            for yy in bestTop...bestBot { for xx in x0...x1 {
                area += 1; if ink[yy * w + xx] { inkCount += 1 }
            } }
            let filled = area > 0 && Double(inkCount) / Double(area) > 0.6

            // Stem: a tall vertical ink run in some column, outside the head band.
            var hasStem = false
            for xx in x0...x1 {
                var run = 0, best = 0
                for yy in 0..<h where !(yy >= bestTop && yy <= bestBot) {
                    if ink[yy * w + xx] { run += 1; best = max(best, run) } else { run = 0 }
                }
                if Double(best) > S * 1.5 { hasStem = true; break }
            }

            let duration: NoteDuration = filled ? .quarter : (hasStem ? .half : .whole)
            heads.append(Head(centerX: (x0 + x1) / 2, centerY: centerY, duration: duration))
        }
        return heads.sorted { $0.centerX < $1.centerX }
    }

    // MARK: - Mapping

    private static func assignBeats(_ heads: [Head], staff: Staff, maxBeats: Double) -> [ScoreNote] {
        var notes: [ScoreNote] = []
        var beat = 0.0
        for head in heads {
            let pitch = pitch(forY: head.centerY, staff: staff)
            let len = head.duration.beats
            if beat + len > maxBeats + 1e-6 { break }   // keep within the score
            notes.append(ScoreNote(pitch: pitch, duration: head.duration, beatOffset: beat))
            beat += len
        }
        return notes
    }

    /// Buffer Y → natural treble pitch. The grayscale buffer's rows run bottom
    /// (row 0) to top, so the visually highest staff line — F5 on a treble staff
    /// — is the one with the LARGEST row index. Each half spacing toward smaller
    /// rows is one diatonic step down, matching `StaffLayout`.
    private static func pitch(forY y: Int, staff: Staff) -> Pitch {
        let topRow = staff.lineYs.max() ?? staff.topY
        let steps = Int((Double(topRow - y) / (staff.spacing / 2)).rounded())
        return StaffLayout.pitch(diatonicStepsBelowTop: steps)
    }
}
