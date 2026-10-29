//
//  StaffSingerSpec.swift
//  StaffSinger
//
//  LeeoKit이 요구하는 앱 계약 구현 (리뷰 요청·만족도·피드백 설정).
//
//  LeeoKit 3.x 부터 `legal`(법적 링크)과 `monetization`(수익모델)은 기본값이
//  없다 — 앱마다 한 번은 반드시 답하게 하려는 의도라, 여기서 명시한다.
//

import Foundation
import LeeoKit

enum StaffSingerSpec: LeeoAppSpec {
    static let appName = "StaffSinger"
    static let developerEmail = "leeo@kakao.com"
    static let feedback = LeeoFeedbackConfig(containerIdentifier: "iCloud.com.Ysoup.FeedbackHub", appIdentifier: "com.devkoan.StaffSinger")

    /// GitHub Pages(`docs/`)로 서비스하는 지원·개인정보 페이지.
    /// 계정 개념이 없는 완전 오프라인 앱이라 `createsAccounts`는 false,
    /// 계정·데이터 삭제 안내 페이지도 필요 없다.
    static let legal = LeeoLegalConfig(
        privacyURL: URL(string: "https://m1zz.github.io/StaffSinger/privacy.html")!,
        supportURL: URL(string: "https://m1zz.github.io/StaffSinger/support.html")!,
        createsAccounts: false)

    /// 결제가 전혀 없는 무료 앱 — 페이월·복원 경로가 따라붙지 않는다.
    static let monetization = LeeoMonetization.free

    /// App Store 앱 ID — 리뷰 링크 · 친구에게 소개하기에 쓴다.
    static var appStoreID: String? { "6779262832" }

    /// 익명 사용 통계 → FeedbackHub. 없으면 bootstrap 이 스냅샷·app_open 을 건너뛴다.
    static let analytics: any LeeoAnalytics = LeeoUsageAnalytics(spec: StaffSingerSpec.self)
}

// MARK: - 팁 (개발자 응원하기)

/// 무료 앱이라 LeeoStore 가 없다. 팁 엔진을 여기 하나 두고, 앱을 열 때 `startStandalone()` 을 부른다.
@MainActor
enum StaffSingerTip {
    static let tipJar = LeeoTipJar(config: LeeoTipJarConfig(productIDs: [
        "com.devkoan.StaffSinger.tip.small",
        "com.devkoan.StaffSinger.tip.medium",
        "com.devkoan.StaffSinger.tip.large",
    ]))
}

/// 팁을 부탁할 만한 순간 — 지금까지 **목소리로 받아써 악보에 넣은** 음표 수. 큰 것부터.
enum StaffSingerTipMoments {
    static let dictatedNotes = [2000, 500, 100]
    private static let key = "tip.dictatedNotes"

    /// 받아쓴 음표를 악보에 넣었을 때 센다.
    static func recordDictated(_ count: Int) {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + count, forKey: key)
    }

    static func reached(dictatedNotes n: Int) -> [LeeoTipMoment] {
        dictatedNotes.filter { n >= $0 }.map { threshold in
            LeeoTipMoment(id: "dictated.\(threshold)",
                          message: String(localized: "지금까지 목소리로 음표 \(n)개를 받아썼어요",
                                          comment: "Tip ask card: how many notes the person has dictated by voice so far"))
        }
    }

    static var reachedNow: [LeeoTipMoment] {
        reached(dictatedNotes: UserDefaults.standard.integer(forKey: key))
    }
}
