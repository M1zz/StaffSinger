//
//  StaffSingerApp.swift
//  StaffSinger
//
//  오선지에 음표를 찍고, 박자와 음높이를 실제 소리로 들려주는 앱.
//

import SwiftUI
import LeeoKit

@main
struct StaffSingerApp: App {
    init() {
        // 사용량 기록 · 크래시 진단 · 익명 사용 통계 (FeedbackHub)
        LeeoKit.bootstrap(StaffSingerSpec.self)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .leeoSatisfactionCheck(StaffSingerSpec.self)
                .task { await StaffSingerTip.tipJar.startStandalone() }
                // 창 크기로 접힘을 재서 아래로 흘린다. 시트 · 알림창도 접힌 선을 비킨다 (LeeoKit Fold).
                .foldAware()
        }
    }
}
