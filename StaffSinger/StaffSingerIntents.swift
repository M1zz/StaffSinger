//
//  StaffSingerIntents.swift
//  StaffSinger
//
//  Siri · 단축어로 바로 시작한다.
//   - "초견으로 악보 찍어줘": 카메라를 연다(찍으면 음표로 읽는다).
//   - "초견 재생": 지금 악보를 들려준다.
//   - "초견 계이름 받아쓰기": 도레미로 말해 음표를 적는 화면을 연다.
//

import AppIntents
import Foundation

@MainActor @Observable
final class StaffSingerRouter {
    enum Request { case scan, play, dictation }
    static let shared = StaffSingerRouter()
    /// 첫 화면이 받아 실행하고 비운다.
    var request: Request?
}

struct ScanScoreIntent: AppIntent {
    static let title = LocalizedStringResource("악보 찍기", comment: "Siri: open the camera to scan sheet music")
    static let description = IntentDescription(
        LocalizedStringResource("카메라로 악보를 찍어 음표로 읽습니다.", comment: "Siri: scan score description")
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        StaffSingerRouter.shared.request = .scan
        return .result()
    }
}

struct PlayScoreIntent: AppIntent {
    static let title = LocalizedStringResource("악보 재생", comment: "Siri: play the current score")
    static let description = IntentDescription(
        LocalizedStringResource("지금 악보를 소리로 들려줍니다.", comment: "Siri: play score description")
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        StaffSingerRouter.shared.request = .play
        return .result()
    }
}

struct SolfegeDictationIntent: AppIntent {
    static let title = LocalizedStringResource("계이름 받아쓰기", comment: "Siri: open solfège dictation")
    static let description = IntentDescription(
        LocalizedStringResource("도레미로 말하면 음표로 적습니다.", comment: "Siri: dictation description")
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        StaffSingerRouter.shared.request = .dictation
        return .result()
    }
}

struct StaffSingerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanScoreIntent(),
            phrases: [
                "Scan sheet music with \(.applicationName)",
                "Scan a score with \(.applicationName)"
            ],
            shortTitle: "Scan Score",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: PlayScoreIntent(),
            phrases: [
                "Play the score in \(.applicationName)",
                "\(.applicationName) play"
            ],
            shortTitle: "Play Score",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: SolfegeDictationIntent(),
            phrases: [
                "Dictate notes in \(.applicationName)",
                "Sing notes into \(.applicationName)"
            ],
            shortTitle: "Note Dictation",
            systemImageName: "mic"
        )
    }
}
