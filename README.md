# StaffSinger 🎼

오선지에 음표를 찍고, **박자와 음높이를 실제 소리로 들려주는** iOS 앱.
"Music Drawing Notation" 류의 앱을 직접 구현한 것으로, 초견(sight-reading) 시
복잡한 박자나 화음 파트를 귀로 확인하는 데 초점을 맞췄습니다.

## 페인 포인트 → 해결

| 문제 | 이 앱의 접근 |
|------|------------|
| 처음 보는 악보의 복잡한 박자가 머릿속에서 안 그려짐 | **메트로놈 클릭 + 카운트인**으로 박을 명확히 들려줌. 재생 중 현재 음표가 주황색으로 하이라이트됨 |
| 화음 파트를 음표만 보고 못 읽음 | **화음 모드(chord mode)**: 같은 박에 음을 쌓으면 동시에 울림. 편집 중에도 즉시 들림 |
| 음높이가 헷갈림 | 음표 선택 시 **C4 / 솔 / 4분음표** 처럼 음이름·계이름·음길이를 표시 |

## 핵심 사용 흐름

1. 오선을 **탭** → 탭한 위치의 음높이로 음표 추가 (추가 즉시 소리 남)
2. 하단 툴바에서 **음길이**(온음표~16분음표) 선택
3. **화음** 버튼을 켜고 음을 추가하면 선택한 음 위에 쌓임 → 화음
4. 음표 선택 후 **♯ / ♭ / ±8va**로 반음·옥타브 이동
5. 상단 **▶︎** 재생 → 메트로놈/카운트인과 함께 박자·음 확인

## 빌드

1. `StaffSinger.xcodeproj`를 Xcode 15+ 에서 열기
2. 타깃 디바이스(또는 시뮬레이터) 선택 후 ⌘R
3. 최소 배포 타깃: iOS 16.0

코드 서명은 Automatic으로 설정돼 있습니다. 실기기 설치 시
`PRODUCT_BUNDLE_IDENTIFIER`(`com.devkoan.StaffSinger`)와 팀만 본인 것으로 바꾸세요.

## 사운드 (중요)

기본 상태에서도 `AVAudioUnitSampler`의 내장 음원으로 소리가 납니다.
**더 좋은 피아노/우드블록 음색**을 원하면 General MIDI SoundFont(.sf2)를
`FluidR3.sf2` 이름으로 앱 타깃에 추가하세요. 무료 SoundFont 예:

- FluidR3_GM (널리 쓰이는 무료 GM 사운드폰트)

파일을 프로젝트에 드래그하고 "Copy items if needed" + 타깃 체크만 하면
`AudioEngine.loadSounds()`가 자동으로 로드합니다. (program 0 = Grand Piano,
program 115 = Woodblock 클릭)

## 아키텍처

```
Models/
  MusicModels.swift     Pitch · NoteDuration · ScoreNote · Score (chordGroups)
  ScoreViewModel.swift  편집 로직 (추가/이동/삭제/화음/설정)
Audio/
  AudioEngine.swift     AVAudioEngine + Sampler, 박자 정확 스케줄러, 메트로놈, 카운트인
Notation/
  StaffLayout.swift     pitch ↔ Y좌표 변환, 레저라인 (순수 geometry)
  StaffView.swift       오선/음자리표/음표 렌더 + 탭으로 음표 추가
Views/
  ContentView.swift     전체 조립
  TransportBar.swift     재생/템포/박자표/설정
  EditorToolbar.swift    음길이·화음·음이동·쉼표·삭제
```

### 설계 메모

- **화음 = 같은 `beatOffset`을 가진 여러 `ScoreNote`.** 모델을 평평하게 유지해
  편집과 스케줄링이 단순해집니다. `Score.chordGroups`가 시간순으로 묶어 줍니다.
- **스케줄러는 박(beat) 단위로 동작**하고 템포로 초를 환산합니다. 메트로놈은
  별도 Task로 동시에 돌려 긴 음/화음 중에도 박이 들립니다.
- `beats`는 4분음표 = 1.0 기준. 6/8 등은 `quarterBeatsPerMeasure`로 환산합니다.

## 다음 단계 아이디어

- MusicXML / MIDI 임포트(기존 악보 불러오기) — 진짜 "초견 도우미"가 되려면 핵심
- 마디 단위 구간 반복(A–B 루프) 연습
- 음표 가로 드래그로 박 위치 이동, 빔(beam) 그룹핑
- 베이스 음자리표 / 큰 보표(grand staff)
- 카메라로 악보 스캔 → 자동 채보 (OMR)
