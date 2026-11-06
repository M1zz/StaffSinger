//
//  ProAccessTests.swift
//  StaffSingerTests
//
//  초견 Pro 의 계약: 상품 ID, 세 번 체험, 페이월 전에 설치한 사람 (→ Pro/StaffSingerPro.swift).
//

import XCTest
import LeeoKit
@testable import StaffSinger

final class ProAccessTests: XCTestCase {

    func testProductIDsMatchStoreConsole() {
        let base = "com.devkoan.StaffSinger.pro"
        XCTAssertEqual(ProProduct.weekly, base + ".weekly")
        XCTAssertEqual(ProProduct.monthly, base + ".monthly")
        XCTAssertEqual(ProProduct.yearly, base + ".yearly")
        XCTAssertEqual(ProProduct.lifetime, base + ".lifetime")
        XCTAssertEqual(ProProduct.graduate, base + ".graduate")
    }

    /// 팁 · 언제나 평생 패스는 Pro 를 열지 않는다.
    func testEntitlementsAreOnlyPro() {
        let config = StaffSingerSpec.paywall
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.entitlementIDs, Set(ProProduct.all))
        XCTAssertFalse(ProProduct.all.contains { $0.contains(".tip.") || $0.contains(".forever") })
    }

    func testEachProFeatureHasThreeFreeTries() {
        guard let policy = StaffSingerSpec.paywall?.gate else { return XCTFail("페이월이 없다") }
        let gate = LeeoGate(policy: policy, hasPro: false, isTrialActive: false)
        for feature in ProFeature.allCases {
            XCTAssertTrue(gate.evaluate(feature.rawValue, current: 0).isAllowed)
            XCTAssertTrue(gate.evaluate(feature.rawValue, current: 2).isAllowed, "세 번째까지는 열린다")
            XCTAssertFalse(gate.evaluate(feature.rawValue, current: 3).isAllowed, "네 번째에 페이월")
        }
        let pro = LeeoGate(policy: policy, hasPro: true, isTrialActive: false)
        XCTAssertTrue(pro.evaluate(ProFeature.dictation.rawValue, current: 100).isAllowed)
    }

    /// 1.0.6 빌드 8 까지 받은 사람은 Pro 를 그대로 쓴다.
    func testBuildsBeforePaywallKeepPro() {
        XCTAssertTrue(ProAccess.isBuildBeforePaywall("1"))
        XCTAssertTrue(ProAccess.isBuildBeforePaywall("8"))
        XCTAssertFalse(ProAccess.isBuildBeforePaywall("9"))
        XCTAssertFalse(ProAccess.isBuildBeforePaywall(""))
    }
}
