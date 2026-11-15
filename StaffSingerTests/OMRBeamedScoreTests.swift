//
//  OMRBeamedScoreTests.swift
//  StaffSingerTests
//
//  악보 읽기의 계약: 꼬리로 묶인 음표도 음높이와 길이를 맞게 읽는다 (→ Notation/OMR.swift).
//  실제 사진 대신 같은 모양을 그려서 시험한다.
//

import XCTest
import UIKit
@testable import StaffSinger

final class OMRBeamedScoreTests: XCTestCase {

    /// 한 줄 악보를 그린다. `step` 은 맨 윗줄(F5)에서 아래로 내려간 칸 수.
    private struct Drawn { let x: CGFloat; let step: Int; var open = false; var stem = true }

    private let S: CGFloat = 24, top: CGFloat = 150

    private func y(_ step: Int) -> CGFloat { top + CGFloat(step) * S / 2 }

    private func score(_ notes: [Drawn], beams: [(from: Int, to: Int, count: Int)] = [],
                       extra: (CGContext) -> Void = { _ in }) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400), format: format).image { r in
            let c = r.cgContext
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
            UIColor.black.setFill(); UIColor.black.setStroke()
            for i in 0..<5 { c.fill(CGRect(x: 0, y: top + CGFloat(i) * S - 1, width: 1200, height: 3)) }
            let stemEnd = top + 4 * S + 2.6 * S          // 기둥은 모두 아래로, 같은 높이까지
            for n in notes {
                let head = CGRect(x: n.x - 0.62 * S, y: y(n.step) - 0.45 * S, width: 1.24 * S, height: 0.9 * S)
                if n.open { c.setLineWidth(4); c.strokeEllipse(in: head.insetBy(dx: 2, dy: 2)) }
                else { c.fillEllipse(in: head) }
                if n.stem { c.fill(CGRect(x: n.x - 0.62 * S, y: y(n.step), width: 3, height: stemEnd - y(n.step))) }
            }
            for b in beams {
                let x0 = notes[b.from].x - 0.62 * S, x1 = notes[b.to].x - 0.62 * S + 3
                for k in 0..<b.count {
                    c.fill(CGRect(x: x0, y: stemEnd - 0.5 * S - CGFloat(k) * 0.75 * S, width: x1 - x0, height: 0.5 * S))
                }
            }
            extra(c)
        }
    }

    func testReadsBeamedGroupsWithPitchAndLength() {
        // 16분 넷(솔 도 레 미) · 8분 둘(레 미) · 4분 하나(미)
        let notes = [Drawn(x: 150, step: 6), Drawn(x: 230, step: 3), Drawn(x: 310, step: 2), Drawn(x: 390, step: 1),
                     Drawn(x: 560, step: 2), Drawn(x: 680, step: 1), Drawn(x: 850, step: 1)]
        let reading = OMR.transcribe(score(notes, beams: [(0, 3, 2), (4, 5, 1)]))
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [67, 72, 74, 76, 74, 76, 76])
        XCTAssertEqual(reading.notes.map(\.duration),
                       [.sixteenth, .sixteenth, .sixteenth, .sixteenth, .eighth, .eighth, .quarter])
        XCTAssertEqual(reading.notes.map(\.beatOffset), [0, 0.25, 0.5, 0.75, 1, 1.5, 2])
        XCTAssertEqual(reading.marks.count, 7)
    }

    /// 꼬리 달린 8분음표 하나 — 실제 글꼴의 ♪ 를 머리가 그 자리에 오도록 그린다.
    /// `up` 이 아니면 위아래로 뒤집어 기둥과 꼬리가 아래로 간다.
    private func flagged(x: CGFloat, step: Int, up: Bool, in c: CGContext) {
        let font = CTFontCreateWithName("Apple Symbols" as CFString, 100, nil)
        var character = Array("♪".utf16), glyph: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let path = CTFontCreatePathForGlyph(font, glyph[0], nil) else { return XCTFail("no ♪ glyph") }
        let box = path.boundingBoxOfPath                 // 글리프는 위가 +y
        let k = 3.9 * S / box.height                     // 머리 0.9칸 + 기둥 3칸
        var t = CGAffineTransform(translationX: x - 0.62 * S, y: y(step) + (up ? 0.45 : -0.45) * S)
            .scaledBy(x: k, y: up ? -k : k)
            .translatedBy(x: -box.minX, y: -box.minY)
        if let placed = path.copy(using: &t) { c.addPath(placed); c.fillPath() }
    }

    func testAFlagIsNotAnotherNote() {
        // 꼬리 달린 8분음표 둘(기둥 위로 · 아래로) 사이에 4분음표 하나 — 음표는 셋뿐이다.
        let image = score([Drawn(x: 600, step: 4)]) { c in
            self.flagged(x: 250, step: 6, up: true, in: c)       // 솔4
            self.flagged(x: 950, step: 1, up: false, in: c)      // 미5
        }
        let reading = OMR.transcribe(image)
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [67, 71, 76])
        XCTAssertEqual(reading.notes.map(\.duration), [.eighth, .quarter, .eighth])
    }

    func testReadsOpenHeads() {
        let notes = [Drawn(x: 200, step: 4), Drawn(x: 500, step: 3, open: true),
                     Drawn(x: 800, step: 5, open: true, stem: false)]
        let reading = OMR.transcribe(score(notes), maxBeats: 16)
        XCTAssertEqual(reading.notes.map(\.duration), [.quarter, .half, .whole])
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [71, 72, 69])
    }

    func testIgnoresLyricsAndBarlines() {
        let notes = [Drawn(x: 300, step: 2), Drawn(x: 700, step: 4)]
        let image = score(notes) { c in
            c.fill(CGRect(x: 500, y: 150, width: 3, height: 96))                    // 세로줄
            for x in stride(from: 280, through: 720, by: 110) {                      // 굵은 가사
                c.fill(CGRect(x: CGFloat(x), y: 340, width: 34, height: 34))
            }
        }
        let reading = OMR.transcribe(image)
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [74, 71])
    }

    func testBarlinesPutEachMeasureOnItsDownbeat() {
        // 앞 마디의 끝 조각(4분 하나) | 온전한 한 마디(4분 넷) — 조각은 빼고 첫 박부터 놓는다.
        let notes = [Drawn(x: 120, step: 3)] + [330, 520, 710, 900].map { Drawn(x: $0, step: 2) }
        let image = score(notes) { c in c.fill(CGRect(x: 220, y: 150, width: 3, height: 96)) }
        let reading = OMR.transcribe(image)
        XCTAssertEqual(reading.notes.map(\.beatOffset), [0, 1, 2, 3])
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [74, 74, 74, 74])
    }

    func testCountsTheMeasuresInView() {
        // 세 마디가 보인다 — 카메라가 "더 가까이"라고 알릴 수 있게 그 수를 센다.
        let image = score([150, 450, 750].map { Drawn(x: $0, step: 2) }) { c in
            for x in [300, 600] { c.fill(CGRect(x: x, y: 150, width: 3, height: 96)) }
        }
        XCTAssertEqual(OMR.transcribe(image).measures, 3)
    }

    func testAMisreadLengthDoesNotShiftTheNextMeasure() {
        // 첫 마디는 세 박뿐(쉼표를 못 읽은 셈) · 둘째 마디는 그래도 다섯째 박에서 시작한다.
        let notes = [150, 300, 450].map { Drawn(x: $0, step: 4) } + [750, 950].map { Drawn(x: $0, step: 2) }
        let image = score(notes) { c in c.fill(CGRect(x: 600, y: 150, width: 3, height: 96)) }
        let reading = OMR.transcribe(image)
        XCTAssertEqual(reading.notes.map(\.beatOffset), [0, 1, 2, 4, 5])
    }

    func testTieJoinsTwoNotesIntoOne() {
        // 같은 음 둘이 붙임줄로 이어짐 → 2분음표 하나. 붙임줄 없는 같은 음 둘은 그대로.
        let notes = [Drawn(x: 200, step: 2), Drawn(x: 330, step: 2), Drawn(x: 600, step: 4), Drawn(x: 730, step: 4)]
        let image = score(notes) { c in
            c.setLineWidth(3)
            c.move(to: CGPoint(x: 220, y: 183))                       // 둘째 줄 아래 칸을 지나는 호
            c.addQuadCurve(to: CGPoint(x: 310, y: 183), control: CGPoint(x: 265, y: 193))
            c.strokePath()
        }
        let reading = OMR.transcribe(image)
        XCTAssertEqual(reading.notes.map(\.duration), [.half, .quarter, .quarter])
        XCTAssertEqual(reading.notes.map(\.beatOffset), [0, 2, 3])
    }

    /// 손에 든 실제 사진으로 확인할 때만 쓴다: `/tmp/omr-photo.jpg` 가 있으면 읽은 결과를 찍는다.
    func testPrintsReadingOfALocalPhoto() throws {
        let path = "/tmp/omr-photo.jpg"
        guard let image = UIImage(contentsOfFile: path) else { throw XCTSkip("no local photo") }
        let reading = OMR.transcribe(image, maxBeats: 64)
        print("OMRPHOTO", reading.notes.map { "\($0.beatOffset)=\($0.pitch.midi):\($0.duration.rawValue)\($0.dotted ? "." : "")" }.joined(separator: " "))
    }
}
