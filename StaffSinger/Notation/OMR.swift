//
//  OMR.swift
//  StaffSinger
//
//  EXPERIMENTAL optical music recognition. A deliberately small, dependency-free
//  classic-CV pipeline for the score people actually photograph: one printed,
//  monophonic staff with beamed groups, lyrics underneath and a little blur. It
//  is NOT a general OMR engine — rests, dots, ties, chords, accidentals and key
//  signatures are not understood, and the clef is assumed to be treble. The user
//  is expected to fix the result by hand afterwards.
//
//  Pipeline: upright → grayscale → Otsu binarize → staff-line detection
//  (horizontal projection) → noteheads (what stays solid when the ink is worn
//  down) → stem → beams/flags at the stem's far end → Y→pitch + duration.
//

import UIKit
import CoreGraphics

enum OMR {

    /// What was read: notes left-to-right with cumulative beats, plus the ids
    /// of those it isn't sure about (head between two staff positions, or
    /// neither clearly filled nor clearly open) so the user checks just those.
    struct Reading {
        var notes: [ScoreNote] = []
        var unsure: Set<UUID> = []
        /// Where each note's head was found, 0...1 from the image's top-left —
        /// so the camera can light up the notes it has read, in place.
        var marks: [CGPoint] = []
    }

    /// Reading a live camera like a long exposure: one frame can be wrong, so a
    /// score is trusted only once the same notes keep coming back.
    struct Exposure {
        static let needed = 5          // 같은 읽기가 이만큼 겹치면 다 찍힌 것
        private static let window = 8  // 최근 몇 번을 겹쳐 볼지

        private struct Key: Hashable { let pitch: Pitch; let duration: NoteDuration }
        private var recent: [[Key]] = []
        /// 0...1 — how developed the picture is. Drops back when the view changes.
        private(set) var progress = 0.0

        /// Add one frame's reading; true once it has fully developed.
        mutating func add(_ reading: Reading) -> Bool {
            let key = reading.notes.map { Key(pitch: $0.pitch, duration: $0.duration) }
            recent.append(key)
            if recent.count > Self.window { recent.removeFirst() }
            let agreeing = key.isEmpty ? 0 : recent.filter { $0 == key }.count
            progress = min(1, Double(agreeing) / Double(Self.needed))
            return progress >= 1
        }
    }

    /// Best-effort transcription; empty if no staff could be found.
    static func transcribe(_ image: UIImage, maxBeats: Double = 8) -> Reading {
        guard let gray = grayscale(upright(image)) else { return Reading() }
        let (ink, threshold) = binarize(gray)
        guard let staff = detectStaff(ink, width: gray.w, height: gray.h) else { return Reading() }
        let heads = detectNotes(gray, ink: ink, threshold: threshold, staff: staff)
        return assignBeats(heads, staff: staff, maxBeats: maxBeats, width: gray.w, height: gray.h)
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
    private static func binarize(_ g: Gray) -> (ink: [Bool], threshold: Int) {
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
        return (g.px.map { Int($0) < threshold }, threshold)
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
            if let staff = pickFiveLines(centers, height: h) { return staff }
        }
        return nil
    }

    /// From candidate line rows, choose 5 evenly spaced ones. When several
    /// staves are in view, the one nearest the middle wins — that is the one the
    /// user lined up; otherwise fall back to the most uniform group.
    private static func pickFiveLines(_ centers: [Int], height h: Int) -> Staff? {
        guard centers.count >= 5 else { return nil }
        let s = centers.sorted()
        var middle: (off: Double, staff: Staff)?
        var uniform: (norm: Double, staff: Staff)?
        for start in 0...(s.count - 5) {
            let win = Array(s[start..<start + 5])
            let gaps = zip(win.dropFirst(), win).map { Double($0 - $1) }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            guard mean > 3 else { continue }
            let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
            let norm = variance / (mean * mean)   // scale-independent
            let staff = Staff(lineYs: win, spacing: mean)
            if norm < 0.02 {
                let off = abs(Double(win[0] + win[4]) / 2 - Double(h) / 2)
                if off < (middle?.off ?? .greatestFiniteMagnitude) { middle = (off, staff) }
            }
            if norm < 0.15, norm < (uniform?.norm ?? .greatestFiniteMagnitude) { uniform = (norm, staff) }
        }
        return middle?.staff ?? uniform?.staff
    }

    // MARK: - Notes

    private struct Head { let centerX: Int; let centerY: Int; let duration: NoteDuration; let unsure: Bool }

    /// A solid lump of ink: its centre, how wide it is, and the pixels of its core.
    private struct Blob { let cx: Int; let cy: Int; let x0: Int; let x1: Int; let core: [Int] }

    /// Find the notes the way they look in real engraving — beamed groups,
    /// lyrics under the staff, a slightly blurred photo:
    ///  1. a notehead is the one thing near a staff that stays solid when the ink
    ///     is worn down by about a third of a staff space (lines and stems wear
    ///     away; beams survive only as long bars, which are dropped);
    ///  2. its stem is traced to the far end, where the beams or flag are counted
    ///     to tell a quarter, an eighth and a sixteenth apart;
    ///  3. open heads (half, whole) are found the same way once their holes are
    ///     filled in.
    private static func detectNotes(_ gray: Gray, ink: [Bool], threshold: Int, staff: Staff) -> [Head] {
        let w = gray.w, h = gray.h, S = staff.spacing
        guard let low = staff.lineYs.min(), let high = staff.lineYs.max() else { return [] }
        // Heads live near the staff; lyrics and neighbouring staves stay out.
        let z0 = max(0, low - Int(2.6 * S)), z1 = min(h, high + Int(2.6 * S) + 1)
        let zh = z1 - z0
        guard zh > 2 else { return [] }
        let zone = Array(ink[(z0 * w)..<(z1 * w)])

        // How thick a pen stroke comes out in this picture (a staff line, and so
        // a stem too). A blurred photo fattens every stroke, so the amount of
        // wearing-down that removes strokes but keeps heads follows this.
        var runs: [Int] = []
        for lineY in staff.lineYs {
            for x in stride(from: 4, to: w, by: 8) where ink[lineY * w + x] {
                var a = lineY, b = lineY
                while a > 0, lineY - a < Int(S), ink[(a - 1) * w + x] { a -= 1 }
                while b < h - 1, b - lineY < Int(S), ink[(b + 1) * w + x] { b += 1 }
                runs.append(b - a + 1)
            }
        }
        runs.sort()
        let stroke = Double(runs.isEmpty ? 1 : runs[runs.count / 2])
        let thickR = Int32((stroke / 2 + 0.05 * S).rounded()) + 1   // strokes are gone
        let coreR = thickR + Int32(max(1, (0.08 * S).rounded()))    // only a head is left

        // A blurred stem can fall under the global threshold, so trace stems on a
        // looser test: a pixel clearly darker than the paper on both its sides.
        var paperSum = 0, paperCount = 0
        for i in 0..<(w * h) where !ink[i] { paperSum += Int(gray.px[i]); paperCount += 1 }
        let paper = paperCount > 0 ? Double(paperSum) / Double(paperCount) : 255
        let margin = 0.3 * (paper - Double(threshold))
        let side = max(2, Int(0.3 * S))
        func stemInk(_ x: Int, _ y: Int) -> Bool {
            let i = y * w + x
            if ink[i] { return true }
            guard x - side >= 0, x + side < w else { return false }
            return Double(min(Int(gray.px[i - side]), Int(gray.px[i + side])) - Int(gray.px[i])) > margin
        }
        let reach0 = max(0, low - Int(4.6 * S)), reach1 = min(h, high + Int(4.6 * S))
        let gap = max(2, Int(0.2 * S))
        /// How far ink runs from (x, y) going `dy`, bridging small breaks.
        func run(_ x: Int, _ y: Int, _ dy: Int) -> Int {
            var n = 0, miss = 0, yy = y
            while yy + dy >= reach0, yy + dy < reach1 {
                yy += dy
                if stemInk(x, yy) { n = abs(yy - y); miss = 0 }
                else { miss += 1; if miss > gap { break } }
            }
            return n
        }
        /// Beams (or a flag) crossing just beside the stem's far end. A staff line
        /// is thin and sits on a known row; two beams blurred into one are thick.
        func beams(stemX: Int, from cy: Int, length n: Int, dir: Int) -> Int {
            let end = cy + dir * n
            let p = end - dir * Int(0.55 * Double(n)), q = end + dir * Int(0.3 * S)
            let a = max(0, min(p, q)), b = min(h, max(p, q))
            var best = 0
            for off in [-0.5, 0.5] {
                let x = Int(Double(stemX) + off * S)
                guard x >= 0, x < w else { continue }
                var count = 0, y = a
                while y < b {
                    guard ink[y * w + x] else { y += 1; continue }
                    var y2 = y
                    while y2 + 1 < b, ink[(y2 + 1) * w + x] { y2 += 1 }
                    let thick = Double(y2 - y + 1), mid = Double(y + y2) / 2
                    let onLine = staff.lineYs.contains { abs(Double($0) - mid) < 0.25 * S }
                    if thick >= 0.3 * S, !(thick < 0.55 * S && onLine) { count += thick > 0.95 * S ? 2 : 1 }
                    y = y2 + 1
                }
                best = max(best, count)
            }
            return best
        }
        func head(_ blob: Blob, open: Bool) -> Head? {
            let cy = blob.cy + z0
            var stem = 0, stemX = blob.cx, dir = 1
            let pad = Int(0.35 * S)
            for x in max(0, blob.x0 - pad)...min(w - 1, blob.x1 + pad) {
                for dy in [1, -1] {
                    let n = run(x, cy, dy)
                    if n > stem { stem = n; stemX = x; dir = dy }
                }
            }
            let hasStem = Double(stem) >= 1.8 * S
            let duration: NoteDuration
            if open {
                duration = hasStem ? .half : .whole
            } else {
                guard hasStem else { return nil }   // a filled head always has a stem
                switch beams(stemX: stemX, from: cy, length: stem, dir: dir) {
                case 0: duration = .quarter
                case 1: duration = .eighth
                default: duration = .sixteenth
                }
            }
            // Unsure: the head lands between two staff positions rather than on one.
            let steps = Double(high - cy) / (S / 2)
            return Head(centerX: blob.cx, centerY: cy, duration: duration,
                        unsure: abs(steps - steps.rounded()) > 0.3)
        }

        let filled = solidBlobs(zone, width: w, height: zh, spacing: S, thickR: thickR, coreR: coreR)
        var heads = filled.compactMap { head($0, open: false) }

        // Open heads: fill head-sized holes, then keep what became solid there.
        let plugged = fillHoles(zone, width: w, height: zh, spacing: S)
        if plugged.any {
            for blob in solidBlobs(plugged.mask, width: w, height: zh, spacing: S, thickR: thickR, coreR: coreR) {
                let fromHole = blob.core.reduce(0) { $0 + (plugged.holes[$1] ? 1 : 0) }
                let isNew = !filled.contains {
                    Double(abs($0.cx - blob.cx)) < 0.8 * S && Double(abs($0.cy - blob.cy)) < 0.8 * S
                }
                if isNew, fromHole * 10 >= blob.core.count * 3, let h = head(blob, open: true) {
                    heads.append(h)
                }
            }
        }
        return heads.sorted { $0.centerX < $1.centerX }
    }

    /// Lumps that stay solid after wearing the ink down, minus the long bars.
    private static func solidBlobs(_ mask: [Bool], width w: Int, height h: Int, spacing S: Double,
                                   thickR: Int32, coreR: Int32) -> [Blob] {
        let d = distance(mask, width: w, height: h)

        // How wide each thick piece is: a beam is a long bar, a head is not.
        var label = [Int32](repeating: 0, count: w * h)
        var widths = [0]
        components(w, h, where: { d[$0] > thickR }) { px in
            var lo = Int.max, hi = 0
            for i in px { lo = min(lo, i % w); hi = max(hi, i % w); label[i] = Int32(widths.count) }
            widths.append(hi - lo + 1)
        }

        var blobs: [Blob] = []
        components(w, h, where: { d[$0] > coreR }) { px in
            var x0 = Int.max, x1 = 0, y0 = Int.max, y1 = 0, sx = 0, sy = 0
            for i in px {
                let x = i % w, y = i / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                sx += x; sy += y
            }
            let bw = Double(x1 - x0 + 1), bh = Double(y1 - y0 + 1)
            guard bw >= 0.25 * S, bh >= 0.25 * S, bw <= 1.6 * S, bh <= 1.4 * S,
                  Double(widths[Int(label[px[0]])]) <= 2.2 * S else { return }
            blobs.append(Blob(cx: Int((Double(sx) / Double(px.count)).rounded()),
                              cy: Int((Double(sy) / Double(px.count)).rounded()),
                              x0: x0, x1: x1, core: px))
        }
        return blobs
    }

    /// Fill enclosed white pockets the size of an open notehead's inside.
    private static func fillHoles(_ mask: [Bool], width w: Int, height h: Int,
                                  spacing S: Double) -> (mask: [Bool], holes: [Bool], any: Bool) {
        var out = mask
        var holes = [Bool](repeating: false, count: w * h)
        var any = false
        components(w, h, where: { !mask[$0] }) { px in
            guard Double(px.count) <= 1.3 * S * S else { return }
            var x0 = Int.max, x1 = 0, y0 = Int.max, y1 = 0
            for i in px {
                let x = i % w, y = i / w
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
            guard x0 > 0, y0 > 0, x1 < w - 1, y1 < h - 1 else { return }   // open to the edge
            let bw = Double(x1 - x0 + 1), bh = Double(y1 - y0 + 1)
            guard bw >= 0.3 * S, bw <= 1.3 * S, bh >= 0.15 * S, bh <= 1.0 * S else { return }
            for i in px { out[i] = true; holes[i] = true }
            any = true
        }
        return (out, holes, any)
    }

    /// Each pixel's distance to the nearest background pixel (the image edge
    /// counts as background) — "how deep inside the ink is this?".
    private static func distance(_ mask: [Bool], width w: Int, height h: Int) -> [Int32] {
        var d = [Int32](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                let i = y * w + x
                var m: Int32 = 0
                if x > 0, y > 0 {
                    m = min(d[i - 1], d[i - w], d[i - w - 1])
                    if x < w - 1 { m = min(m, d[i - w + 1]) }
                }
                d[i] = m + 1
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) where mask[y * w + x] {
                let i = y * w + x
                var m: Int32 = 0
                if x < w - 1, y < h - 1 {
                    m = min(d[i + 1], d[i + w], d[i + w + 1])
                    if x > 0 { m = min(m, d[i + w - 1]) }
                }
                d[i] = min(d[i], m + 1)
            }
        }
        return d
    }

    /// Visit every 4-connected group of pixels for which `on` holds.
    private static func components(_ w: Int, _ h: Int, where on: (Int) -> Bool, _ visit: ([Int]) -> Void) {
        let count = w * h
        var seen = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        for start in 0..<count where !seen[start] && on(start) {
            seen[start] = true
            stack.append(start)
            var px: [Int] = []
            while let i = stack.popLast() {
                px.append(i)
                let x = i % w
                for j in [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i - w, i + w]
                where j >= 0 && j < count && !seen[j] && on(j) {
                    seen[j] = true
                    stack.append(j)
                }
            }
            visit(px)
        }
    }

    // MARK: - Mapping

    private static func assignBeats(_ heads: [Head], staff: Staff, maxBeats: Double,
                                    width w: Int, height h: Int) -> Reading {
        var reading = Reading()
        var beat = 0.0
        for head in heads {
            let pitch = pitch(forY: head.centerY, staff: staff)
            let len = head.duration.beats
            if beat + len > maxBeats + 1e-6 { break }   // keep within the score
            let note = ScoreNote(pitch: pitch, duration: head.duration, beatOffset: beat)
            reading.notes.append(note)
            reading.marks.append(CGPoint(x: Double(head.centerX) / Double(w),
                                         y: 1 - Double(head.centerY) / Double(h)))   // rows run bottom-up
            if head.unsure { reading.unsure.insert(note.id) }
            beat += len
        }
        return reading
    }

    /// Buffer Y → natural treble pitch. The grayscale buffer's rows run bottom
    /// (row 0) to top, so the visually highest staff line — F5 on a treble staff
    /// — is the one with the LARGEST row index. Each half spacing toward smaller
    /// rows is one diatonic step down, matching `StaffLayout`.
    private static func pitch(forY y: Int, staff: Staff) -> Pitch {
        let topRow = staff.lineYs.max() ?? staff.topY
        let steps = Int((Double(topRow - y) / (staff.spacing / 2)).rounded())
        return StaffLayout(clef: .treble).pitch(diatonicStepsBelowTop: steps)
    }
}
