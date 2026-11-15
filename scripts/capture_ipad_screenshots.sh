#!/bin/sh
# iPad 스크린샷(2064x2752, 꾸미지 않은 화면 그대로 제출본)을 iPad Pro 13" 시뮬레이터에서 찍는다.
# 사용법: sh scripts/capture_ipad_screenshots.sh <UDID> <앱 경로(.app)> [언어 ...]
# 앱은 DEBUG 빌드의 -screenshotScene 으로 그 화면을 연다 (ContentView.applyScreenshotScene). iPad 는 가로로 돌아간다.
# 시뮬레이터는 세로 그대로 저장하므로 바로 세워 2752x2064 로 둔다.
# 결과: docs/screenshots/marketing/<언어>/ipad-NN-<장면>.png
set -e
UDID=$1; APP=$2; shift 2
BID=com.devkoan.StaffSinger
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LANGS=${*:-"ko en en-GB zh-Hans zh-Hant ja ru es de fr it pt-BR th vi cs da el fi id nb nl pl sv tr"}
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3
for L in $LANGS; do
  OUT="$ROOT/docs/screenshots/marketing/$L"; mkdir -p "$OUT"
  echo "▸ $L"
  N=0
  for S in piano playback dictation; do
    N=$((N+1))
    xcrun simctl terminate "$UDID" $BID 2>/dev/null || true
    sleep 1
    xcrun simctl launch "$UDID" $BID -AppleLanguages "($L)" -screenshotScene $S -hasSeenOnboarding YES >/dev/null
    sleep ${WAIT:-6}
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/ipad-0$N-$S.png" >/dev/null 2>&1
    sips -r 270 "$OUT/ipad-0$N-$S.png" >/dev/null
    echo "  $OUT/ipad-0$N-$S.png"
  done
done
xcrun simctl terminate "$UDID" $BID 2>/dev/null || true
