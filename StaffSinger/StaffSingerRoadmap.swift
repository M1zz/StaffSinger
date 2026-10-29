//
//  StaffSingerRoadmap.swift
//  StaffSinger
//
//  **앞으로 만들 것**의 원본. 설정 ▸ 앞으로 만들 기능(`LeeoRoadmapView`)이 이 목록을 그대로 보여 준다.
//
//  ⚠️ 개발하다 "이건 다음에" 가 생기면 **여기에 한 줄을 더한다.** 코드의 TODO 주석으로만 남기지 않는다.
//     - 새 항목: `.planned`. 손대기 시작하면 `.building`. 내보내면 `.shipped("1.2.0")`.
//     - id 는 한 번 정하면 바꾸지 않는다(문구는 바꿔도 된다).
//     - 문구는 사용자 말로 쓴다(내부 이름 · 기술 용어 금지). 영어는 StaffSinger/Localizable.xcstrings 에 넣는다
//       (앱의 다른 화면은 한국어 하나지만, 이 화면 문구만은 en · ko 를 둘 다 둔다).
//     - 사용자에게 보일 만한 것만 적는다. 리팩터링 · 시험 · 빌드 설정은 `.sprintcommander/tasks.json` 의 몫이다.
//

import SwiftUI
import LeeoKit

extension StaffSingerSpec {
    static var roadmap: [LeeoRoadmapItem] {[
        // MARK: 다음에 만들어요
        .init(id: "fix.easy", status: .shipped("1.0.5"),
              title: NSLocalizedString("더 쉬운 음표 고치기", comment: "Roadmap item: easier note fixing"),
              detail: NSLocalizedString("되돌리기, 건반으로 다시 치기, 흥얼거려 고치기로 틀린 음을 금방 바로잡아요.", comment: "Roadmap item detail: easier note fixing")),
        .init(id: "photo.play", status: .planned,
              title: NSLocalizedString("찍은 악보 위에서 바로 연주", comment: "Roadmap item: play right on the photo"),
              detail: NSLocalizedString("종이 악보를 찍으면 사진 속 음표가 차례로 빛나며 소리가 나요. 잘못 읽은 음은 그 자리에서 바로 고쳐요.", comment: "Roadmap item detail: play right on the photo")),
        .init(id: "photo.anyangle", status: .planned,
              title: NSLocalizedString("비스듬히 찍어도 괜찮아요", comment: "Roadmap item: shoot from any angle"),
              detail: NSLocalizedString("틀에 맞추지 않아도 앱이 악보를 찾아 반듯하게 펴서 읽어요.", comment: "Roadmap item detail: shoot from any angle")),
        .init(id: "photo.accuracy", status: .planned,
              title: NSLocalizedString("악보를 더 정확하게 읽기", comment: "Roadmap item: sharper score reading"),
              detail: NSLocalizedString("더 많은 종류의 악보를 더 정확하게 알아봐요.", comment: "Roadmap item detail: sharper score reading")),
        .init(id: "sing.check", status: .planned,
              title: NSLocalizedString("따라 부르면 음정 확인", comment: "Roadmap item: sing along and check pitch"),
              detail: NSLocalizedString("악보를 따라 부르면 음마다 맞았는지, 높았는지 낮았는지 알려 줘요.", comment: "Roadmap item detail: sing along and check pitch")),
        .init(id: "practice.slow", status: .planned,
              title: NSLocalizedString("어려운 마디만 천천히", comment: "Roadmap item: slow down tricky bars"),
              detail: NSLocalizedString("어려운 마디를 골라 음높이는 그대로, 느리게 되풀이해 들어요.", comment: "Roadmap item detail: slow down tricky bars")),
        .init(id: "autosave", status: .planned,
              title: NSLocalizedString("쓰던 악보 이어서 쓰기", comment: "Roadmap item: keep the score you were writing"),
              detail: NSLocalizedString("앱이 꺼졌다 다시 열려도 쓰던 악보가 그대로 남아 있어요.", comment: "Roadmap item detail: keep the score")),
        .init(id: "backup", status: .planned,
              title: NSLocalizedString("악보 저장과 내보내기", comment: "Roadmap item: save and export scores"),
              detail: NSLocalizedString("만든 악보를 파일로 저장하고 다시 불러올 수 있어요.", comment: "Roadmap item detail: save and export scores")),
        .init(id: "display.dark", status: .shipped("1.0.5"),
              title: NSLocalizedString("다크 모드", comment: "Roadmap item: dark mode"),
              detail: NSLocalizedString("어두운 화면에서도 악보와 단추가 또렷하게 보여요.", comment: "Roadmap item detail: dark mode")),
        .init(id: "onboarding", status: .planned,
              title: NSLocalizedString("처음 쓰는 분을 위한 안내", comment: "Roadmap item: onboarding"),
              detail: NSLocalizedString("처음 열었을 때 무엇을 할 수 있는지 짧게 보여 줘요.", comment: "Roadmap item detail: onboarding")),
        .init(id: "tips", status: .planned,
              title: NSLocalizedString("쓰는 요령 알려 주기", comment: "Roadmap item: tips"),
              detail: NSLocalizedString("알아 두면 편한 기능을 알맞은 때에 살짝 알려 줘요.", comment: "Roadmap item detail: tips")),
        .init(id: "whatsnew", status: .planned,
              title: NSLocalizedString("업데이트 소식", comment: "Roadmap item: what's new"),
              detail: NSLocalizedString("업데이트 뒤 처음 열 때 무엇이 새로 생겼는지 알려 줘요.", comment: "Roadmap item detail: what's new")),
        .init(id: "notifications", status: .planned,
              title: NSLocalizedString("연습 알림", comment: "Roadmap item: practice reminders"),
              detail: NSLocalizedString("잊지 않도록 정한 시간에 시창 연습을 알려 줘요.", comment: "Roadmap item detail: practice reminders")),
        .init(id: "widgets", status: .planned,
              title: NSLocalizedString("홈 화면 위젯", comment: "Roadmap item: home screen widgets"),
              detail: NSLocalizedString("앱을 열지 않고 홈 화면에서 바로 연습을 시작해요.", comment: "Roadmap item detail: home screen widgets")),
        .init(id: "shortcuts", status: .planned,
              title: NSLocalizedString("Siri와 단축어", comment: "Roadmap item: Siri and Shortcuts"),
              detail: NSLocalizedString("Siri에게 말하거나 단축어로 바로 실행해요.", comment: "Roadmap item detail: Siri and Shortcuts")),
        .init(id: "lang.english", status: .shipped("1.0.4"),
              title: NSLocalizedString("영어 지원", comment: "Roadmap item: English"),
              detail: NSLocalizedString("앱을 영어로도 쓸 수 있어요.", comment: "Roadmap item detail: English")),
        .init(id: "lang.more", status: .shipped("1.0.4"),
              title: NSLocalizedString("더 많은 언어", comment: "Roadmap item: more languages"),
              detail: NSLocalizedString("더 많은 나라 말로 앱을 쓸 수 있게 해요.", comment: "Roadmap item detail: more languages")),
        .init(id: "a11y.voiceover", status: .shipped("1.0.5"),
              title: NSLocalizedString("VoiceOver로 더 편하게", comment: "Roadmap item: better VoiceOver support"),
              detail: NSLocalizedString("화면 읽기 기능이 단추와 내용을 빠짐없이, 알맞은 순서로 읽어 줘요.", comment: "Roadmap item detail: better VoiceOver support")),
        .init(id: "a11y.largetext", status: .shipped("1.0.5"),
              title: NSLocalizedString("큰 글씨에 맞춘 화면", comment: "Roadmap item: layouts that fit large text sizes"),
              detail: NSLocalizedString("글자 크기를 키워도 잘리지 않고 보기 좋게 다시 배치돼요.", comment: "Roadmap item detail: large text layouts")),
        .init(id: "a11y.contrast", status: .shipped("1.0.5"),
              title: NSLocalizedString("보기 편한 색과 대비", comment: "Roadmap item: better colors and contrast"),
              detail: NSLocalizedString("대비를 높이거나 색을 구별하기 어려워도 내용을 알아볼 수 있어요.", comment: "Roadmap item detail: colors and contrast")),
        .init(id: "a11y.motion", status: .shipped("1.0.5"),
              title: NSLocalizedString("움직임 줄이기", comment: "Roadmap item: reduce motion"),
              detail: NSLocalizedString("움직임 줄이기를 켜면 화면 효과가 차분해져요.", comment: "Roadmap item detail: reduce motion")),
        .init(id: "fold", status: .planned,
              title: NSLocalizedString("펼치는 아이폰 화면", comment: "Roadmap item: foldable iPhone layout"),
              detail: NSLocalizedString("펼치는 아이폰에서 넓은 화면을 두 쪽으로 나눠 써요.", comment: "Roadmap item detail: foldable iPhone layout")),
    ]}
}

// MARK: - 화면

/// 설정 ▸ 앞으로 만들 기능. 설정 패널이 내비게이션 스택 밖이라 시트로 연다.
/// "이런 기능이 있으면 좋겠어요" 는 기능 제안으로 시작하는 피드백 화면을 연다.
struct RoadmapScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showFeedback = false

    var body: some View {
        NavigationStack {
            LeeoRoadmapView<StaffSingerSpec>(onSuggest: { showFeedback = true })
                .navigationDestination(isPresented: $showFeedback) {
                    LeeoFeedbackView<StaffSingerSpec>(initialType: .feature)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
    }
}
