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
        LeeoEngagement.shared.registerLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .leeoSatisfactionCheck(StaffSingerSpec.self)
        }
    }
}
