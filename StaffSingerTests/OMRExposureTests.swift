//
//  OMRExposureTests.swift
//  StaffSingerTests
//
//  비춰 읽기의 계약: 거듭 같게 읽힌 음표가 왼쪽부터 하나씩 확정되고,
//  끝내 안 겹치는 음표는 포기하고 표시한 채 넘어간다 (→ Notation/OMR.swift).
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

    func testNotesSettleFromTheLeftOneAFrame() {
        var e = OMR.Exposure()
        for _ in 1..<OMR.Exposure.needed {
            XCTAssertEqual(e.add(reading([60, 62, 64])), .waiting)
        }
        XCTAssertEqual(e.add(reading([60, 62, 64])), .settled(0, Pitch(midi: 60)))
        XCTAssertEqual(e.add(reading([60, 62, 64])), .settled(1, Pitch(midi: 62)))
        XCTAssertEqual(e.add(reading([60, 62, 64])), .settled(2, Pitch(midi: 64)))
        XCTAssertNil(e.result)
        XCTAssertEqual(e.add(reading([60, 62, 64])), .done)
        XCTAssertEqual(e.result?.notes.map(\.pitch.midi), [60, 62, 64])
        XCTAssertEqual(e.result?.unsure, [])
        XCTAssertEqual(e.progress, 1)
    }

    func testEmptyReadingsNeverSettle() {
        var e = OMR.Exposure()
        for _ in 0..<20 { XCTAssertEqual(e.add(reading([])), .waiting) }
        XCTAssertEqual(e.progress, 0)
    }

    func testOneBadFrameDoesNotSpoilTheReading() {
        var e = OMR.Exposure()
        for _ in 0..<3 { _ = e.add(reading([60, 62])) }           // 60 확정
        XCTAssertEqual(e.add(reading([65, 62])), .waiting)         // 흔들린 한 장
        XCTAssertEqual(e.add(reading([60, 62])), .settled(1, Pitch(midi: 62)))
        XCTAssertEqual(e.add(reading([60, 62])), .done)
        XCTAssertEqual(e.result?.unsure, [])
    }

    func testANoteThatNeverAgreesIsGivenUpAndFlagged() {
        var e = OMR.Exposure()
        var steps: [OMR.Exposure.Step] = []
        // 둘째 음표가 장면마다 다르게 읽힌다.
        for i in 0..<30 where e.result == nil {
            steps.append(e.add(reading([60, 70 + i, 64])))
        }
        XCTAssertEqual(steps.filter { $0 != .waiting },
                       [.settled(0, Pitch(midi: 60)), .failed(1), .settled(2, Pitch(midi: 64)), .done])
        XCTAssertEqual(e.failed, [1])
        XCTAssertEqual(e.result?.notes.count, 3)
        XCTAssertEqual(e.result?.unsure, (e.result?.notes[1].id).map { Set([$0]) })
    }

    func testRetryReadsOnlyTheNotesThatCameOutWrong() {
        var e = OMR.Exposure()
        for _ in 0..<10 where e.result == nil { _ = e.add(reading([60, 62, 64])) }
        XCTAssertNotNil(e.result)
        e.retry([1])                                               // 둘째 음표가 틀렸다
        XCTAssertNil(e.result)
        XCTAssertEqual(e.failed, [1])
        var steps: [OMR.Exposure.Step] = []
        for _ in 0..<10 where e.result == nil { steps.append(e.add(reading([60, 65, 64]))) }
        XCTAssertEqual(steps.filter { $0 != .waiting }, [.settled(1, Pitch(midi: 65)), .done])
        XCTAssertEqual(e.result?.notes.map(\.pitch.midi), [60, 65, 64])
        XCTAssertEqual(e.result?.unsure, [])
    }

    func testMovingToAnotherScoreStartsOver() {
        var e = OMR.Exposure()
        for _ in 0..<4 { _ = e.add(reading([60, 62])) }
        XCTAssertEqual(e.settled, 2)
        var steps: [OMR.Exposure.Step] = []
        for _ in 0..<14 where e.result == nil { steps.append(e.add(reading([67, 69]))) }
        XCTAssertEqual(e.result?.notes.map(\.pitch.midi), [67, 69])
        XCTAssertEqual(steps.filter { $0 != .waiting },
                       [.settled(0, Pitch(midi: 67)), .settled(1, Pitch(midi: 69)), .done])
    }
}
