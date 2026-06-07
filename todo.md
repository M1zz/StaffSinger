# StaffSinger TODO

## 완료
- [x] 빌드 에러 점검 — `xcodebuild` 결과 **BUILD SUCCEEDED** (에러 없음)
- [x] iOS 시뮬레이터(iPhone 17 Pro)에 설치 및 실행 확인
- [x] 하단 툴바 음길이 버튼이 `?`(빈 박스)로 깨지던 문제 수정
  - 원인: 유니코드 Musical Symbols 블록(U+1D1xx: 𝅝 𝅗𝅥 𝅘𝅥𝅯)을 시스템 폰트가 미지원
  - 해결: `NoteDurationGlyph`(SwiftUI Canvas)로 음표를 직접 그려 폰트 의존 제거
    (`Views/EditorToolbar.swift`)
- [x] 가로모드 전용으로 변경
  - `Info.plist`: `UISupportedInterfaceOrientations`(+`~ipad`)에서 Portrait 제거,
    LandscapeLeft/Right만 남김
  - `project.pbxproj`: `INFOPLIST_KEY_UISupportedInterfaceOrientations[sdk=iphoneos*]`
    (Debug/Release)에서 Portrait 제거
  - 빌드된 앱 Info.plist에 Landscape 두 방향만 존재함을 확인
- [x] 가로모드 화면 재설계 (사용성 + 가운데 정렬 + 하단 여백)
  - `StaffView`: GeometryReader로 오선을 **세로 중앙 정렬**, 가용 높이/너비를
    꽉 채움 (기존 topLineY:70·height:320 고정 → 동적 계산). 세로 기준 고정 높이
    합산으로 상단 바·툴바 둘째 줄이 잘리던 오버플로 해결
  - `ContentView`: StaffView를 `maxHeight: .infinity`로 유연화, 선택 정보
    스트립 가운데 정렬
  - `EditorToolbar`: 2행 액션 버튼 가운데 그룹 정렬, 프로스티드 배경을
    하단 안전영역 끝까지(`ignoresSafeArea(edges: .bottom)`) 확장 + 하단 여백 정리
- [x] 음표 입력 인터랙션 개선 + 컨트롤 토글
  - 누름→드래그→**뗄 때 음표 확정** (`StaffView` DragGesture onChanged/onEnded)
  - 떼기 전 **흐릿한 고스트 음표 + 레저라인 + 음높이 배지**(예: "F6 · 파") 표시
  - 음높이 변경 시 **미리듣기 사운드 스크럽**(`AudioEngine.previewNote/endPreview`)
    + **햅틱**(`UISelectionFeedbackGenerator`), 확정 시 임팩트 햅틱
  - `ContentView` ZStack 재설계: 오선=전체화면 캔버스, **재생 버튼만 항상 우상단**,
    메트로놈·설정·제목·음표 패널은 하단 **그래버로 함께 접기/펼치기**
  - 패널 빈 공간 터치가 오선으로 통과해 음표가 추가되던 버그 → `contentShape`로 차단
- [x] 2마디 고정 + 가운데 정렬 + 음표 도구 토글
  - `StaffView`: 가로 스크롤 제거, **정확히 2마디**(시작/중간/굵은 끝 마디줄)를
    가용 폭에 맞춰 동적 beatWidth로 배치, 좌우 여백 동일하게 **가운데 정렬**.
    2마디를 벗어나는 음표는 렌더 생략
  - `ContentView`: 음표 도구 패널 **기본 숨김**(`showControls = false`),
    우상단에 **♪ 토글 버튼** 추가(열림 시 ▼). 접힘 상태 하단은 완전히 비움
    (기존 "음표 도구" 그래버 제거)
- [x] 음표 이동 / 롱프레스 삭제 / 쉼표 자동채움 / 세이프 에어리어
  - **음표 이동**: 음표별 히트 타겟에 드래그 제스처(세로=음높이, 가로=박 스냅),
    이동 중 미리듣기+햅틱. 좌표공간 `staff` 사용, `vm.moveNote`
  - **롱프레스 삭제**: 히트 타겟에 `onLongPressGesture`(0.4s) → 삭제 + 강한 햅틱
  - 안정성: `noteLayer`를 `score.notes` 플랫 순회(id 키)로 바꿔 드래그 중 재정렬 방지.
    `tapCatcher`를 노트 레이어 아래로 내려 빈 곳=추가, 노트 위=이동/삭제로 분리
  - **재생 시 쉼표 자동채움**: `vm.fillRestsForPlayback()` — 음표 사이 빈 박과
    마지막 미완성 마디(최대 2마디)를 그리디로 표준 쉼표 묶어 채움. `play()`에서 호출
  - 쉼표 글리프도 유니코드(U+1D13x) 미지원 → `drawRest`로 직접 그림(온/2분/4분/8/16분)
  - **세이프 에어리어**: 배경만 풀블리드, 오선·컨트롤은 세이프 에어리어 내부 →
    다이나믹 아일랜드/홈 인디케이터와 겹치지 않음
- [x] 클리프 왼쪽/2번째 마디 오른쪽 잘림 수정
  - 원인: ZStack 첫 자식 `Color.ignoresSafeArea()`가 ZStack을 풀스크린으로
    확장 → StaffView가 세이프 에어리어를 무시하고 가장자리까지 깔려 클리프/끝
    마디가 다이나믹 아일랜드·홈 인디케이터에 붙음
  - 해결: 배경을 ZStack 자식이 아니라 `.background(Color…ignoresSafeArea())`로
    이동 → 콘텐츠는 세이프 에어리어 존중, 배경만 풀블리드.
    landscape-left/right 양방향에서 여백 확보 확인
- [x] 첫 실행 시 오선지만 표시
  - 빈 악보일 때(첫 실행)는 상단 버튼(재생·음표도구·메트로놈·설정) 전부 숨기고
    오선지만 표시. 음표가 하나라도 생기면 버튼이 페이드인으로 나타남
  - `ContentView.controlsVisible = !score.notes.isEmpty || showControls`로 게이팅
  - 빈 오선을 탭하면 음표가 추가되므로 버튼 없이도 시작 가능
- [x] 높은음자리표 수직 가운데 정렬
  - SF 폰트의 트레블 클리프 글리프가 텍스트 박스 안에서 낮게 앉아 너무 낮게
    보이던 문제 → 클리프 y를 가운데 줄 기준 -22pt 올려 오선 수직 중앙에 맞춤
    (`clef()`의 `.position` y = midLineY - 22)
- [x] 클리프 정확히 정중앙 + 음표 위치 미리보기 가시성 개선
  - 클리프: 렌더링 픽셀 측정으로 보정 → `y = midLineY - 6`에서 클리프 시각
    중심이 가운데 줄과 정확히 일치(측정 오차 0.2pt)
  - 미리보기 손가락 가림 해결: 고스트를 손가락 아래가 아니라 **실제 놓일
    위치(landing beat)** 에 표시 + 음높이를 가로지르는 **점선 가이드라인(오선 전폭)**
    + 크고 선명한 음높이 라벨(예: "C6 · 도"). `GhostPreview` 뷰로 교체,
    미사용 `previewPoint` 제거

## 다음 단계 아이디어 (README 참고)
- [ ] MusicXML / MIDI 임포트
- [ ] 마디 단위 A–B 루프 연습
- [ ] 음표 가로 드래그로 박 위치 이동, 빔 그룹핑
- [ ] 베이스 음자리표 / 큰 보표
