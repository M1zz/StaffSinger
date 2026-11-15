//
//  OMR.swift
//  StaffSinger
//
//  EXPERIMENTAL optical music recognition. A deliberately small, dependency-free
//  classic-CV pipeline for the score people actually photograph: one printed,
//  monophonic staff with beamed groups, lyrics underneath and a little blur. It
//  is NOT a general OMR engine — rests, dots, chords, accidentals and key
//  signatures are not understood, and the clef is assumed to be treble. The user
//  is expected to fix the result by hand afterwards.
//
//  Pipeline: upright → grayscale → Otsu binarize → staff-line detection
//  (horizontal projection) → noteheads (what stays solid when the ink is worn
//  down) → stem → beams/flags at the stem's far end → Y→pitch + duration →
//  ties joined → barlines put each measure on its own downbeat.
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
        /// The five staff lines it read from, top to bottom, 0...1 from the top —
        /// empty if no staff was found. Shows the user which staff is being read.
        var staffLines: [Double] = []
        /// How many measures were in view. More than the score holds means the
        /// camera is too far away — the caller can say so.
        var measures = 0
    }

    /// Reading a live camera note by note. One frame can be wrong, so a note is
    /// trusted only once frames keep agreeing on it — and the notes settle from
    /// the left, one per frame, each resting on the ones before it. A note the
    /// frames can't agree on is given up on (and flagged) so the rest can go on.
    /// Once it is done, `retry` reads just the notes that came out wrong again.
    struct Exposure {
        static let needed = 3          // 같은 음표가 이만큼 겹쳐 읽히면 확정
        static let patience = 6        // 이만큼 봐도 안 겹치면 그 음표는 포기
        private static let window = 8  // 최근 몇 번을 겹쳐 볼지

        /// What one more frame did.
        enum Step: Equatable { case waiting, settled(Int, Pitch), failed(Int), done }

        private struct Key: Hashable { let pitch: Pitch; let beats: Double }
        private enum Next: Hashable { case note(Key), end }

        private var recent: [Reading] = []
        private var slots: [Key?] = []   // 왼쪽부터 확정한 음표. nil 은 포기한 자리
        private var redo: [Int]?         // 다시 읽을 자리들. nil 이면 처음 읽는 중
        private var waited = 0
        /// The newest frame that agrees with everything settled so far — its
        /// marks say where the settled notes are on screen right now.
        private(set) var view = Reading()
        /// The whole score, once every note has settled. Given-up notes are in `unsure`.
        private(set) var result: Reading?

        var settled: Int { slots.count }
        var failed: [Int] { slots.indices.filter { slots[$0] == nil } }
        /// 0...1 — how far along the score it has settled.
        var progress: Double {
            if result != nil { return 1 }
            return view.notes.isEmpty ? 0 : min(1, Double(slots.count) / Double(view.notes.count))
        }

        private func key(_ note: ScoreNote) -> Key { Key(pitch: note.pitch, beats: note.beats) }

        /// Does this frame read the settled notes the same way?
        private func fits(_ reading: Reading) -> Bool {
            !reading.notes.isEmpty && reading.notes.count >= slots.count
                && zip(slots, reading.notes).allSatisfy { $0 == nil || $0 == key($1) }
        }

        /// Add one frame's reading. At most one note settles per frame.
        mutating func add(_ reading: Reading) -> Step {
            guard result == nil else { return .done }
            recent.append(reading)
            if recent.count > Self.window { recent.removeFirst() }
            let fitting = recent.filter(fits)
            if fitting.isEmpty {
                // 한동안 아무 장면도 맞지 않으면 다른 악보를 비춘 것 — 처음부터.
                // (다시 읽는 중에는 확정한 음표를 버리지 않고 기다린다.)
                if redo == nil, recent.count == Self.window, !slots.isEmpty {
                    slots = []; waited = 0; view = Reading()
                }
                return .waiting
            }
            guard fits(reading) else { return .waiting }
            view = reading
            if redo?.isEmpty == true { return finish(fitting) }

            // 그 자리에 무엇이 있는지 장면마다 한 표. 가장 많은 것, 같으면 더 새것.
            let n = redo?.first ?? slots.count
            let next: [Next] = fitting.map { $0.notes.count > n ? .note(key($0.notes[n])) : .end }
            var best = Next.end, most = 0
            for candidate in next.reversed() {
                let votes = next.filter { $0 == candidate }.count
                if votes > most { best = candidate; most = votes }
            }
            let agreed = most >= Self.needed
            if !agreed {
                waited += 1
                guard waited >= Self.patience else { return .waiting }
            }
            waited = 0

            switch best {
            case .note(let key):
                if redo == nil { slots.append(agreed ? key : nil) } else {
                    slots[n] = agreed ? key : nil
                    redo?.removeFirst()
                }
                return agreed ? .settled(n, key.pitch) : .failed(n)
            case .end:
                return finish(fitting)
            }
        }

        /// The score is whole once a frame reads exactly the settled notes.
        private mutating func finish(_ fitting: [Reading]) -> Step {
            guard var whole = fitting.last(where: { $0.notes.count == slots.count }) else { return .waiting }
            for i in failed { whole.unsure.insert(whole.notes[i].id) }
            view = whole
            result = whole
            return .done
        }

        /// Read these notes again, from fresh frames, keeping all the others.
        mutating func retry(_ indices: [Int]) {
            guard result != nil else { return }
            let again = Set(indices).union(failed).filter(slots.indices.contains).sorted()
            for i in again { slots[i] = nil }
            redo = again
            recent = []
            waited = 0
            result = nil
        }
    }

    /// Best-effort transcription; empty if no staff could be found.
    /// `measureBeats` is how long one measure is; when barlines are found, each
    /// measure starts on its own downbeat instead of running on from the last.
    static func transcribe(_ image: UIImage, maxBeats: Double = 8, measureBeats: Double = 4) -> Reading {
        guard let gray = grayscale(upright(image)) else { return Reading() }
        let (ink, threshold) = binarize(gray)
        guard let staff = detectStaff(ink, width: gray.w, height: gray.h) else { return Reading() }
        let w = gray.w, h = gray.h
        let stroke = strokeWidth(ink, width: w, height: h, staff: staff)
        var heads = detectNotes(gray, ink: ink, threshold: threshold, staff: staff, stroke: stroke)
        let bars = detectBarlines(ink, width: w, height: h, staff: staff, heads: heads)
        heads = joinTies(heads, barlines: bars, ink: ink, width: w, height: h, staff: staff)
        var reading = assignBeats(heads, barlines: bars, staff: staff, measureBeats: measureBeats,
                                  maxBeats: maxBeats, width: w, height: h)
        reading.staffLines = staff.lineYs.map { 1 - Double($0) / Double(gray.h) }.sorted()   // rows run bottom-up
        return reading
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

    private struct Head {
        let centerX: Int; let centerY: Int
        var duration: NoteDuration; let unsure: Bool
        var dotted = false
        /// Its stem — the column it runs in and the row of its far end — and how
        /// much solid ink the head has. Tells a head from the flag on its stem.
        var stemX = 0, stemEnd = 0, size = 0
        var beats: Double { duration.beats * (dotted ? 1.5 : 1) }
    }

    /// A solid lump of ink: its centre, how wide it is, and the pixels of its core.
    private struct Blob { let cx: Int; let cy: Int; let x0: Int; let x1: Int; let core: [Int] }

    /// Find the notes the way they look in real engraving — beamed groups,
    /// lyrics under the staff, a slightly blurred photo:
    ///  1. a notehead is the one thing near a staff that stays solid when the ink
    ///     is worn down by about a third of a staff space (lines and stems wear
    ///     away; beams survive only as long bars, which are dropped);
    ///  2. its stem is traced to the far end, where the beams or flag are counted
    ///     to tell a quarter, an eighth and a sixteenth apart;
    ///  3. a flag sits at the far end of a head's stem. It can look like a second
    ///     note there — as a small solid lump, or as the pocket it closes off
    ///     against the stem and a staff line, which looks like an open head —
    ///     so anything at the far end of a filled head's stem is its flag;
    ///  4. open heads (half, whole) are found the same way once their holes are
    ///     filled in.
    private static func detectNotes(_ gray: Gray, ink: [Bool], threshold: Int, staff: Staff,
                                    stroke: Double) -> [Head] {
        let w = gray.w, h = gray.h, S = staff.spacing
        guard let low = staff.lineYs.min(), let high = staff.lineYs.max() else { return [] }
        // Heads live near the staff; lyrics and neighbouring staves stay out.
        let z0 = max(0, low - Int(2.6 * S)), z1 = min(h, high + Int(2.6 * S) + 1)
        let zh = z1 - z0
        guard zh > 2 else { return [] }
        let zone = Array(ink[(z0 * w)..<(z1 * w)])

        // A blurred photo fattens every stroke, so the amount of wearing-down
        // that removes strokes but keeps heads follows the stroke width.
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
                        unsure: abs(steps - steps.rounded()) > 0.3,
                        stemX: stemX, stemEnd: cy + dir * stem, size: blob.core.count)
        }

        let filled = solidBlobs(zone, width: w, height: zh, spacing: S, thickR: thickR, coreR: coreR)
        var heads = filled.compactMap { head($0, open: false) }

        // A flag: something at the far end of a filled head's stem. Two heads of
        // a chord share a stem too, but they sit together at its near end.
        func atFarEnd(_ f: Head, of n: Head) -> Bool {
            Double(abs(f.stemX - n.stemX)) < 0.5 * S
                && Double(abs(f.centerY - n.stemEnd)) < 2.2 * S
                && Double(abs(n.centerY - f.stemEnd)) < 2.2 * S
        }
        // Of two solid lumps on one stem, the clearly smaller one is the flag.
        func isFlag(_ f: Head, of n: Head) -> Bool { atFarEnd(f, of: n) && f.size * 3 < n.size * 2 }
        let lumps = heads
        heads = lumps.filter { f in !lumps.contains { isFlag(f, of: $0) } }.map { n in
            var n = n   // 꼬리가 달렸으면 적어도 8분음표다
            if n.duration == .quarter, lumps.contains(where: { isFlag($0, of: n) }) { n.duration = .eighth }
            return n
        }
        let solid = heads.count

        // Open heads: fill head-sized holes, then keep what became solid there.
        let plugged = fillHoles(zone, width: w, height: zh, spacing: S)
        if plugged.any {
            for blob in solidBlobs(plugged.mask, width: w, height: zh, spacing: S, thickR: thickR, coreR: coreR) {
                let fromHole = blob.core.reduce(0) { $0 + (plugged.holes[$1] ? 1 : 0) }
                let isNew = !filled.contains {
                    Double(abs($0.cx - blob.cx)) < 0.8 * S && Double(abs($0.cy - blob.cy)) < 0.8 * S
                }
                guard isNew, fromHole * 10 >= blob.core.count * 3, let h = head(blob, open: true) else { continue }
                // 꼬리가 기둥 · 오선과 둘러싼 빈칸은 속 빈 음표가 아니라 그 음표의 꼬리다.
                if let i = heads[..<solid].firstIndex(where: { atFarEnd(h, of: $0) }) {
                    if heads[i].duration == .quarter { heads[i].duration = .eighth }
                } else {
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

    /// How thick a pen stroke comes out in this picture (a staff line, and so a
    /// stem too): the typical height of the staff lines.
    private static func strokeWidth(_ ink: [Bool], width w: Int, height h: Int, staff: Staff) -> Double {
        let cap = Int(staff.spacing)
        var runs: [Int] = []
        for lineY in staff.lineYs {
            for x in stride(from: 4, to: w, by: 8) where ink[lineY * w + x] {
                var a = lineY, b = lineY
                while a > 0, lineY - a < cap, ink[(a - 1) * w + x] { a -= 1 }
                while b < h - 1, b - lineY < cap, ink[(b + 1) * w + x] { b += 1 }
                runs.append(b - a + 1)
            }
        }
        runs.sort()
        return Double(runs.isEmpty ? 1 : runs[runs.count / 2])
    }

    // MARK: - Barlines and ties

    /// Barlines: thin strokes running the full height of the staff with no
    /// notehead beside them (a stroke beside a head is its stem).
    private static func detectBarlines(_ ink: [Bool], width w: Int, height h: Int,
                                       staff: Staff, heads: [Head]) -> [Int] {
        let S = staff.spacing
        guard let low = staff.lineYs.min(), let high = staff.lineYs.max() else { return [] }
        let gap = max(2, Int(0.15 * S))
        var bars: [Int] = []
        var x = 0
        func spansStaff(_ x: Int) -> Bool {
            var miss = 0
            for y in low...high {
                if ink[y * w + x] { miss = 0 } else { miss += 1; if miss > gap { return false } }
            }
            return true
        }
        while x < w {
            guard spansStaff(x) else { x += 1; continue }
            var x2 = x
            while x2 + 1 < w, spansStaff(x2 + 1) { x2 += 1 }
            let mid = (x + x2) / 2
            if Double(x2 - x + 1) <= 0.8 * S,
               !heads.contains(where: { Double(abs($0.centerX - mid)) < S }) { bars.append(mid) }
            x = x2 + 1
        }
        return bars
    }

    /// Two neighbouring notes of the same pitch joined by an arc are one longer
    /// note. They are merged when the sum is a length we can write (plain or
    /// dotted) and no barline stands between them.
    private static func joinTies(_ heads: [Head], barlines: [Int], ink: [Bool],
                                 width w: Int, height h: Int, staff: Staff) -> [Head] {
        let S = staff.spacing
        /// An arc between the two heads: in most columns between them there is
        /// ink just above or just below that is not a staff line.
        func arc(_ a: Head, _ b: Head) -> Bool {
            var x0 = a.centerX + Int(0.8 * S), x1 = b.centerX - Int(0.8 * S)
            if x1 - x0 < 3 { x0 = a.centerX + Int(0.6 * S); x1 = b.centerX - Int(0.6 * S) }
            guard x1 - x0 >= 3 else { return false }
            let cy = (a.centerY + b.centerY) / 2
            for side in [1, -1] {
                let p = cy + side * Int(0.45 * S), q = cy + side * Int(1.7 * S)
                let r0 = max(0, min(p, q)), r1 = min(h - 1, max(p, q))
                guard r0 < r1 else { continue }
                var hits = 0
                for x in x0...x1 {
                    var y = r0, found = false
                    while y <= r1, !found {
                        guard ink[y * w + x] else { y += 1; continue }
                        var y2 = y
                        while y2 + 1 <= r1, ink[(y2 + 1) * w + x] { y2 += 1 }
                        let mid = Double(y + y2) / 2
                        found = Double(y2 - y + 1) < 0.5 * S
                            && !staff.lineYs.contains { abs(Double($0) - mid) < 0.3 * S }
                        y = y2 + 1
                    }
                    if found { hits += 1 }
                }
                if hits * 10 >= (x1 - x0 + 1) * 6 { return true }
            }
            return false
        }
        func writable(_ beats: Double) -> (NoteDuration, Bool)? {
            for d in NoteDuration.allCases {
                if abs(d.beats - beats) < 1e-6 { return (d, false) }
                if abs(d.beats * 1.5 - beats) < 1e-6 { return (d, true) }
            }
            return nil
        }
        var out: [Head] = []
        for head in heads {
            if var last = out.last,
               pitch(forY: last.centerY, staff: staff) == pitch(forY: head.centerY, staff: staff),
               !barlines.contains(where: { $0 > last.centerX && $0 < head.centerX }),
               let (duration, dotted) = writable(last.beats + head.beats),
               arc(last, head) {
                last.duration = duration
                last.dotted = dotted
                out[out.count - 1] = last
            } else {
                out.append(head)
            }
        }
        return out
    }

    // MARK: - Mapping

    /// Lay the notes out in time. Without barlines they simply follow one
    /// another. With barlines each measure starts on its own downbeat, so one
    /// misread length cannot push everything after it out of place — and a
    /// scrap of a neighbouring measure caught at the edge of the picture is
    /// left out rather than counted as the first beat.
    private static func assignBeats(_ heads: [Head], barlines: [Int], staff: Staff,
                                    measureBeats: Double, maxBeats: Double,
                                    width w: Int, height h: Int) -> Reading {
        // Split at the barlines; remember how wide each piece is.
        let edges = [0] + barlines + [w]
        var measures: [(heads: [Head], width: Int)] = []
        for i in 0..<(edges.count - 1) {
            let inside = heads.filter { $0.centerX >= edges[i] && $0.centerX < edges[i + 1] }
            if !inside.isEmpty { measures.append((inside, edges[i + 1] - edges[i])) }
        }
        let byMeasure = !barlines.isEmpty && measureBeats > 0
        if byMeasure, measures.count >= 2 {
            func beats(_ m: (heads: [Head], width: Int)) -> Double { m.heads.reduce(0) { $0 + $1.beats } }
            let widest = measures.map(\.width).max() ?? 1
            let anyFull = measures.contains { abs(beats($0) - measureBeats) < 1e-6 }
            func isScrap(_ m: (heads: [Head], width: Int)) -> Bool {
                beats(m) < measureBeats - 1e-6 && (anyFull || m.width * 2 < widest)
            }
            if let first = measures.first, isScrap(first) { measures.removeFirst() }
            if measures.count >= 2, let last = measures.last, isScrap(last) { measures.removeLast() }
        }

        var reading = Reading()
        reading.measures = measures.count
        var beat = 0.0
        for (index, measure) in measures.enumerated() {
            if byMeasure { beat = Double(index) * measureBeats }
            let end = byMeasure ? min(beat + measureBeats, maxBeats) : maxBeats
            for head in measure.heads {
                if beat + head.beats > end + 1e-6 { break }   // keep within the measure / the score
                var note = ScoreNote(pitch: pitch(forY: head.centerY, staff: staff),
                                     duration: head.duration, beatOffset: beat)
                note.dotted = head.dotted
                reading.notes.append(note)
                reading.marks.append(CGPoint(x: Double(head.centerX) / Double(w),
                                             y: 1 - Double(head.centerY) / Double(h)))   // rows run bottom-up
                if head.unsure { reading.unsure.insert(note.id) }
                beat += head.beats
            }
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
