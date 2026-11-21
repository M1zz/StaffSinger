//
//  OMRClefTests.swift
//  StaffSingerTests
//
//  악보 읽기의 계약: 오선이 시작하는 곳의 음자리표를 알아보고, 음높이를 그 음자리표로 읽는다
//  (→ Notation/OMR.swift). 실제 글꼴의 음자리표를 그려서 시험한다.
//

import XCTest
import UIKit
import CoreText
@testable import StaffSinger

final class OMRClefTests: XCTestCase {

    private let S: CGFloat = 24, top: CGFloat = 150, lineStart: CGFloat = 60

    private func y(_ step: Int) -> CGFloat { top + CGFloat(step) * S / 2 }

    /// 음자리표 하나와 4분음표 몇 개. `notes` 는 맨 윗줄에서 아래로 내려간 칸 수.
    /// `from`…`to` 는 음자리표가 차지하는 높이 (맨 윗줄 = 0, 칸 단위).
    private func score(_ glyph: String?, from: CGFloat = 0, to: CGFloat = 4,
                       notes: [Int], lineStart: CGFloat? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let start = lineStart ?? self.lineStart
        return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 400), format: format).image { r in
            let c = r.cgContext
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
            UIColor.black.setFill()
            for i in 0..<5 { c.fill(CGRect(x: start, y: top + CGFloat(i) * S - 1, width: 1200 - start, height: 3)) }
            if let glyph { draw(glyph, x: start + 10, from: from, to: to, in: c) }
            for (k, step) in notes.enumerated() {
                let x = 300 + CGFloat(k) * 200
                c.fillEllipse(in: CGRect(x: x - 0.62 * S, y: y(step) - 0.45 * S, width: 1.24 * S, height: 0.9 * S))
                c.fill(CGRect(x: x + 0.62 * S - 3, y: y(step) - 3.3 * S, width: 3, height: 3.3 * S))
            }
        }
    }

    /// 글꼴의 음자리표를 `from`…`to` 높이에 맞춰 그린다 (없으면 시스템이 대신 찾은 글꼴).
    private func draw(_ glyph: String, x: CGFloat, from: CGFloat, to: CGFloat, in c: CGContext) {
        let base = CTFontCreateWithName("Apple Symbols" as CFString, 100, nil)
        let font = CTFontCreateForString(base, glyph as CFString, CFRange(location: 0, length: (glyph as NSString).length))
        var chars = Array(glyph.utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { return XCTFail("no \(glyph) glyph") }
        let box = path.boundingBoxOfPath                     // 글리프는 위가 +y
        let k = (to - from) * S / box.height
        var t = CGAffineTransform(translationX: x, y: top + to * S)
            .scaledBy(x: k, y: -k)
            .translatedBy(x: -box.minX, y: -box.minY)
        if let placed = path.copy(using: &t) { c.addPath(placed); c.fillPath() }
    }

    func testTrebleClef() {
        let reading = OMR.transcribe(score("\u{1D11E}", from: -1.6, to: 5.6, notes: [6, 4]), clef: .bass)
        XCTAssertEqual(reading.clef, .treble)
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [67, 71])        // 솔4 · 시4
    }

    func testBassClef() {
        let reading = OMR.transcribe(score("\u{1D122}", from: -0.1, to: 3.1, notes: [6, 4]))
        XCTAssertEqual(reading.clef, .bass)
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [47, 50])        // 시2 · 레3
    }

    func testAltoClef() {
        let reading = OMR.transcribe(score("\u{1D121}", from: 0, to: 4, notes: [6, 4]))
        XCTAssertEqual(reading.clef, .alto)
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [57, 60])        // 라3 · 도4
    }

    /// 오선이 사진 가장자리에서 들어오면 음자리표가 보이지 않는다 — 지금 음자리표로 읽는다.
    func testNoClefInViewKeepsTheGivenClef() {
        let reading = OMR.transcribe(score(nil, notes: [6, 4], lineStart: 0), clef: .bass)
        XCTAssertNil(reading.clef)
        XCTAssertEqual(reading.notes.map(\.pitch.midi), [47, 50])
    }
}
