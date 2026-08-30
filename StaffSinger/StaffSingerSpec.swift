//
//  StaffSingerSpec.swift
//  StaffSinger
//
//  LeeoKit이 요구하는 앱 계약 구현 (리뷰 요청·만족도·피드백 설정).
//

import Foundation
import LeeoKit

enum StaffSingerSpec: LeeoAppSpec {
    static let appName = "StaffSinger"
    static let developerEmail = "leeo@kakao.com"
    static let feedback = LeeoFeedbackConfig(containerIdentifier: "iCloud.com.Ysoup.FeedbackHub", appIdentifier: "com.devkoan.StaffSinger")
}
