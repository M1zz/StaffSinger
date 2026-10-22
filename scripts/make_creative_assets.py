#!/usr/bin/env python3
"""App Store 크리에이티브 자산(제품 페이지 헤더 · 검색 결과) 생성: HTML → 헤드리스 Chrome.

사용법: python3 scripts/make_creative_assets.py [언어 ...]     (없으면 전부)

자리
  docs/screenshots/creative/<스토어 로케일>/header.png   3840x1646  제품 페이지 맨 위
  docs/screenshots/creative/<스토어 로케일>/search.png   3840x2560  검색 결과 (없으면 스크린샷이 대신 보인다)

⚠️ 안전 영역 밖은 기기에 따라 잘린다. 글은 **반드시** 안전 영역 안에 둔다(배경 · 기기 그림은 넘쳐도 된다).
   수치는 Apple 공식 PSD 템플릿에서 잰 값이다(https://developer.apple.com/app-store/asset-best-practices/).
   아이폰에서 헤더는 가운데만 남고, 검색 결과는 약 385pt 폭으로 줄어 보인다. 그래서 글이 크다.

⚠️ 가격 · 할인 · 주소(URL) · 수상 · 다른 플랫폼 이름은 넣지 않는다(Apple 가이드).
"""
import shutil, subprocess, sys, pathlib, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw" / "creative"
OUT = ROOT / "docs" / "screenshots" / "creative"
ICON = ROOT / "StaffSinger" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 앱 언어 코드 → App Store Connect 로케일 (make_marketing_screenshots.py 와 같다)
STORE = {"ko": "ko", "en": "en-US", "en-GB": "en-GB", "ja": "ja", "ru": "ru", "es": "es-MX", "de": "de-DE", "fr": "fr-FR", "it": "it", "pt-BR": "pt-BR"}   # 스토어에는 한국어 한 가지

# (가로, 세로, 안전 영역 left, top, right, bottom)
SPEC = {
    "header": (3840, 1646, (1097, 493, 2743, 1154)),
    "search": (3840, 2560, (836, 765, 3004, 1795)),
}

# 눈썹글 · 헤드라인 · 보조 문장은 검색 결과에 쓴다. 기기 화면(오선지 + 피아노 건반으로 음표 넣기)과 같은 이야기다.
# 눈썹글은 검색어(악보 · 오선보)다.
SEARCH = {
    "ko": ("오선지 악보", "찍은 음표를<br>바로 들어 봐요", "건반으로 넣고<br>박자 그대로 재생해요"),
    "en": ("Sheet music", "Hear the notes<br>you put down", "Enter them on the keys,<br>play back at the right rhythm"),
    "en-GB": ("Sheet music", "Hear the notes<br>you put down", "Enter them on the keys,<br>play back at the right rhythm"),
    "ja": ("五線譜の楽譜", "書いた音符を、<br>すぐ聴ける", "鍵盤で入力して、<br>リズムそのままに再生"),
    "ru": ("Ноты", "Слышно сразу,<br>что вы записали", "Ставьте ноты на клавишах,<br>слушайте в нужном ритме"),
    "es": ("Partitura", "Escucha las notas<br>que escribes", "Entra con el teclado,<br>escucha con su ritmo"),
    "de": ("Noten", "Gesetzte Noten<br>sofort hören", "Mit Tasten eingeben,<br>im richtigen Rhythmus abspielen"),
    "fr": ("Partition", "Écoutez les notes<br>que vous écrivez", "Saisissez au clavier,<br>jouez au bon rythme"),
    "it": ("Spartito", "Ascolta le note<br>che scrivi", "Inserisci con la tastiera,<br>ascolta con il ritmo giusto"),
    "pt-BR": ("Partitura", "Ouça as notas<br>que você coloca", "Entre com o teclado,<br>ouça no ritmo certo"),
}

# 헤더는 한 가지 약속: 처음 보는 악보(초견)도 소리로 확인한다.
HEADER = {
    "ko": ("초견", "처음 보는 악보도<br>소리로 확인해요"),
    "en": ("StaffSinger", "Check a new score<br>by ear"),
    "en-GB": ("StaffSinger", "Check a new score<br>by ear"),
    "ja": ("StaffSinger", "初見の譜面を、<br>耳で確認"),
    "ru": ("StaffSinger", "Новые ноты —<br>проверьте на слух"),
    "es": ("StaffSinger", "Comprueba una partitura<br>nueva de oído"),
    "de": ("StaffSinger", "Neue Noten<br>mit dem Gehör prüfen"),
    "fr": ("StaffSinger", "Une nouvelle partition<br>à l’oreille"),
    "it": ("StaffSinger", "Un nuovo spartito<br>da controllare a orecchio"),
    "pt-BR": ("StaffSinger", "Uma partitura nova<br>conferida de ouvido"),
}

# ⚠️ 바탕 · 글자색은 앱 아이콘(파란 바탕 위 흰 오선과 음표)과 AccentColor(#3373D9) 에서 왔다.
# 앱은 가로 화면으로만 쓰므로 기기도 가로로 눕힌다.
BASE_CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; }
body { background:linear-gradient(150deg,#5AA6F7 0%%,#3B82E6 45%%,#2459C4 100%%); position:relative;
  font-family:-apple-system, "SF Pro Display", "Apple SD Gothic Neo", sans-serif; }
.staff { position:absolute; left:0; width:100%%; height:4px; background:rgba(255,255,255,.22); }
.glow { position:absolute; border-radius:50%%; filter:blur(160px); pointer-events:none; }
.text { position:absolute; display:flex; flex-direction:column; justify-content:center; }
.eyebrow { font-weight:700; color:#D6E8FF; letter-spacing:-0.01em; line-height:1.15; }
.headline { font-weight:800; color:#ffffff; letter-spacing:-0.03em; line-height:1.12; text-wrap:balance; }
.sub { font-weight:500; color:rgba(255,255,255,.82); letter-spacing:-0.01em; line-height:1.35; text-wrap:balance; }
/* 한국어는 낱말 중간에서 끊지 않는다. */
:lang(ko) .headline, :lang(ko) .sub, :lang(ko) .eyebrow { word-break:keep-all; }
.phone { position:absolute; background:#10213f; border:6px solid #5b7fb8; padding:36px; border-radius:170px;
  box-shadow: 0 60px 160px rgba(10,30,80,.45); }
.phone img { width:100%%; display:block; border-radius:136px; }
.note { position:absolute; color:#fff; opacity:.9; font-family:"Apple Symbols","Bravura",serif; }
"""

# 글이 상자를 넘지 않을 때까지 줄인다. 잘리는 글은 없다 - 끝까지 안 맞으면 표시하고 멈춘다.
FIT_JS = """
<script>
// 문구에 적은 줄(<br>)보다 더 쪼개지면 "Rispondi / con un / tocco" 처럼 읽기가 끊긴다.
// 적은 줄 수를 지킬 때까지 줄인다.
function lines(el) {
  return Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight));
}
function fit(box, el, max, min) {
  const want = el.querySelectorAll('br').length + 1;
  let size = max;
  el.style.fontSize = size + 'px';
  while (size > min && (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 ||
         lines(el) > want)) {
    size -= 4; el.style.fontSize = size + 'px';
  }
  if (box.scrollHeight > box.clientHeight + 1 || box.scrollWidth > box.clientWidth + 1 || lines(el) > want)
    document.body.dataset.overflow = '1';
}
document.fonts.ready.then(() => {
  const box = document.querySelector('.text');
  const h = document.querySelector('.headline');
  fit(box, h, +h.dataset.max, +h.dataset.min);
  document.body.dataset.done = '1';
});
</script>
"""


def phone(img, left, top, width, rotate=0):
    return (f'<div class="phone" style="left:{left}px;top:{top}px;width:{width}px;'
            f'transform:rotate({rotate}deg)"><img src="{img}"></div>')


def staff_lines(top, gap=70):
    """아이콘의 흰 오선. 바탕 장식이다."""
    return "".join(f'<div class="staff" style="top:{top + i * gap}px"></div>' for i in range(5))


def search_html(lang):
    W, H, (l, t, r, b) = SPEC["search"]
    eyebrow, headline, sub = SEARCH[lang]
    sw, sh = r - l, b - t
    col = int(sw * 0.50)
    # 가로 기기가 안전 영역 오른쪽 몫에서 화면 오른쪽 밖으로 넘친다(기기 그림은 잘려도 된다).
    ph_w = 1740
    ph_left = l + col + 40
    ph_top = (H - int(ph_w * 1320 / 2868) - 84) // 2
    img = (RAW / lang / "01-piano.png").as_uri()
    return f"""
{staff_lines(250)}{staff_lines(2000)}
<div class="glow" style="left:{ph_left - 200}px;top:600px;width:2000px;height:1400px;background:rgba(255,255,255,.18)"></div>
{phone(img, ph_left, ph_top, ph_w, 0)}
<div class="text" style="left:{l}px;top:{t}px;width:{col}px;height:{sh}px">
  <div class="eyebrow" style="font-size:96px">{eyebrow}</div>
  <div class="headline" data-max="250" data-min="140" style="margin-top:36px">{headline}</div>
  <div class="sub" style="font-size:84px;margin-top:52px">{sub}</div>
</div>"""


def header_html(lang):
    W, H, (l, t, r, b) = SPEC["header"]
    eyebrow, headline = HEADER[lang]
    sw, sh = r - l, b - t
    left_img = (RAW / lang / "02-staff.png").as_uri()
    right_img = (RAW / lang / "01-piano.png").as_uri()
    notes = [(1150, 150, 230, -8, "♪"), (2560, 120, 200, 10, "♫"), (1300, 1270, 180, 6, "♩"), (2450, 1240, 220, -6, "♪")]
    notes_html = "".join(f'<div class="note" style="left:{x}px;top:{y}px;font-size:{z}px;transform:rotate({rot}deg)">{ch}</div>'
                         for x, y, z, rot, ch in notes)
    return f"""
{staff_lines(140)}{staff_lines(1230)}
<div class="glow" style="left:{l - 200}px;top:{t - 400}px;width:{sw + 400}px;height:{sh + 800}px;background:rgba(255,255,255,.14)"></div>
{notes_html}
{phone(left_img, -240, 470, 1400, -8)}
{phone(right_img, 2680, 470, 1400, 8)}
<div class="text" style="left:{l}px;top:{t}px;width:{sw}px;height:{sh}px;align-items:center;text-align:center">
  <div class="eyebrow" style="font-size:76px">{eyebrow}</div>
  <div class="headline" data-max="210" data-min="110" style="margin-top:22px">{headline}</div>
</div>"""


def html_lang(lang):
    return {"zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"}.get(lang, lang)


def render(lang, kind):
    W, H, _ = SPEC[kind]
    body = search_html(lang) if kind == "search" else header_html(lang)
    page = (f'<!doctype html><html lang="{html_lang(lang)}"><head><meta charset="utf-8"><style>'
            f'{BASE_CSS % {"W": W, "H": H}}</style></head><body>{body}{FIT_JS}</body></html>')
    html_path = pathlib.Path(tempfile.gettempdir()) / f"staffsinger-creative-{lang}-{kind}.html"
    html_path.write_text(page, encoding="utf-8")
    # 글이 끝까지 안 맞으면 그림을 만들지 않는다(잘린 글이 스토어에 올라가는 것보다 낫다).
    dom = subprocess.run([CHROME, "--headless=new", "--dump-dom", f"--window-size={W},{H}",
                          "--force-device-scale-factor=1", "--disable-gpu", "--virtual-time-budget=3000",
                          html_path.as_uri()], capture_output=True, text=True, timeout=90).stdout
    if 'data-done="1"' not in dom:
        raise SystemExit(f"글 맞추기가 끝나지 않았다: {lang} {kind}")
    if 'data-overflow="1"' in dom:
        raise SystemExit(f"글이 안전 영역을 넘는다: {lang} {kind} - 문구를 줄일 것")
    out_dir = OUT / STORE.get(lang, lang)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_png = out_dir / f"{kind}.png"
    # ⚠️ Chrome 은 가끔 아무것도 안 그리고 끝나거나 멈춘다. 세 번까지 한다.
    for _ in range(3):
        try:
            r = subprocess.run([CHROME, "--headless=new", f"--screenshot={out_png}",
                                f"--window-size={W},{H}", "--force-device-scale-factor=1",
                                "--hide-scrollbars", "--disable-gpu", "--virtual-time-budget=3000",
                                "--allow-file-access-from-files", html_path.as_uri()],
                               capture_output=True, timeout=90)
        except subprocess.TimeoutExpired:
            continue
        if r.returncode == 0:
            break
    else:
        raise SystemExit(f"Chrome 이 그리지 못했다: {out_png}")
    print(f"rendered {out_png}")


if __name__ == "__main__":
    langs = sys.argv[1:] or list(SEARCH)
    for lang in langs:
        if lang not in SEARCH:
            raise SystemExit(f"모르는 언어: {lang} (아는 것: {', '.join(SEARCH)})")
        for kind in ("header", "search"):
            render(lang, kind)
