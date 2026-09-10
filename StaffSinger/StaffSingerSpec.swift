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
}
