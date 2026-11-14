//
//  OMRExposureTests.swift
//  StaffSingerTests
//
//  비춰 읽기의 계약: 같은 악보가 거듭 읽혀야만 다 찍힌다 (→ Notation/OMR.swift).
//

import XCTest
@testable import StaffSinger

final class OMRExposureTests: XCTestCase {

    private func reading(_ midis: [Int]) -> OMR.Reading {
        var r = OMR.Reading()
        for (i, m) in midis.enumerated() {
            r.notes.append(ScoreNote(pitch: Pitch(midi: m), duration: .quarter, beatOffset: Double(i)))
        }
        return r
    }

    func testDevelopsOnlyAfterRepeatedAgreement() {
        var e = OMR.Exposure()
        for _ in 1..<OMR.Exposure.needed {
            XCTAssertFalse(e.add(reading([60, 62, 64])))
        }
        XCTAssertTrue(e.add(reading([60, 62, 64])))
        XCTAssertEqual(e.progress, 1)
    }

    func testEmptyReadingsNeverDevelop() {
        var e = OMR.Exposure()
        for _ in 0..<20 { XCTAssertFalse(e.add(reading([]))) }
        XCTAssertEqual(e.progress, 0)
    }

    func testOneBadFrameDoesNotSpoilThePicture() {
        var e = OMR.Exposure()
        for _ in 0..<3 { _ = e.add(reading([60, 62])) }
        XCTAssertFalse(e.add(reading([60, 65])))          // 흔들린 한 장
        XCTAssertFalse(e.add(reading([60, 62])))
        XCTAssertTrue(e.add(reading([60, 62])))
    }

    func testMovingToAnotherScoreStartsOver() {
        var e = OMR.Exposure()
        for _ in 0..<4 { _ = e.add(reading([60, 62])) }
        XCTAssertFalse(e.add(reading([67, 69])))
        XCTAssertLessThan(e.progress, 0.5)
    }
}
