# App Review 답장 — 인앱 결제 위치 (Guideline 2.1(b))

새 빌드(설정 패널의 회색 줄을 고친 것)를 올린 **뒤에** App Store Connect ▸ 앱 ▸ 앱 심사 메시지에 아래 영어 본문을 붙인다.
같은 본문을 '앱 심사 정보 ▸ 메모'에도 넣어 두면 다음 심사에서 같은 질문이 안 나온다.

무슨 일이었나: 1.0.6 (10) 에서 설정 옆 패널의 '개발자 응원하기' 줄이 회색으로 눌리지 않았다.
패널에 `NavigationStack` 이 없어 다른 화면으로 넘어가는 줄이 모두 죽어 있었다. 상품 설정 문제가 아니었다.

---

Hello,

Thank you for pointing this out. You were right: in build 1.0.6 (10) the "Support the Developer" row in Settings was greyed out because of a bug in the Settings panel, so the tips could not be reached. This is fixed in the new build we have just submitted.

Where to find every In-App Purchase in the new build:

Tips (Small Tip, Medium Tip, Large Tip)
1. Launch the app. Tap the Settings button (the slider icon) at the far right of the top bar.
2. Scroll to the bottom of the Settings panel.
3. Tap "Support the Developer" (heart icon). The three tips are listed there.

StaffSinger Pro (yearly subscription and lifetime)
1. Open Settings as above.
2. "StaffSinger Pro" is the first item at the top. Tap it.
3. The purchase screen shows both options. "Restore Purchases" is in the top right corner.

The In-App Purchases are not restricted by storefront or device, and no sign-in is needed. The Paid Apps Agreement is active.

Thank you.
