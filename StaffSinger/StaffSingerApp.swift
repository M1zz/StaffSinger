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
                // 아랍어에서도 숫자는 0-9 (박자표 4/4 · C4 · 120 BPM 과 섞이지 않게).
                .environment(\.locale, .app)
                .leeoSatisfactionCheck(StaffSingerSpec.self)
                // 개발자가 보낸 의견에 답장하면, 앱이 앞으로 올 때 답장을 시트로 보여 준다 (LeeoKit).
                .leeoFeedbackReplyNotice(StaffSingerSpec.self)
                .task { await StaffSingerTip.tipJar.startStandalone() }
                // 창 크기로 접힘을 재서 아래로 흘린다. 시트 · 알림창도 접힌 선을 비킨다 (LeeoKit Fold).
                .foldAware()
        }
    }
}

// MARK: - Numbers in Arabic

extension Locale {
    /// The locale numbers are written in. Arabic keeps 0-9: the staff, the time signature,
    /// note names (C4) and tempo (120 BPM) carry digits that can't follow the device, and a
    /// Saudi device's default ١٢٣ next to them reads as two scripts. Every other language is
    /// the device's own locale.
    static var app: Locale {
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("ar") == true else { return .current }
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(identifier: "ar")
        components.numberingSystem = "latn"
        return Locale(components: components)
    }
}
