#!/usr/bin/env python3
"""App Store 마케팅 스크린샷: 원본 캡처 + 헤드라인 → HTML → 헤드리스 Chrome (appstore-assets 스킬).

사용법: python3 scripts/make_marketing_screenshots.py [언어 ...]   (없으면 전부)

자리
  docs/screenshots/raw/<언어>/NN-….png          원본 캡처 (가로 2868x1320, 스토어에 안 올라감)
  docs/screenshots/marketing/<로케일>/NN-….png   제출본 2688x1242 (가로) — DeployBar 가 이 폴더를 그대로 올린다
슬라이드마다 배치(layout)를 달리한다: top · left-text · right-text · dark (가로 화면용)
"""
import subprocess, sys, pathlib, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "docs" / "screenshots" / "raw"
OUT = ROOT / "docs" / "screenshots" / "marketing"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 2688, 1242   # 아이폰 제출 규격을 가로로 — 앱이 가로 화면으로만 돈다

# 앱 언어 → App Store 로케일
STORE = {"ko": "ko", "en": "en-US", "en-GB": "en-GB", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "ja": "ja", "ru": "ru", "es": "es-MX", "de": "de-DE", "fr": "fr-FR", "it": "it", "pt-BR": "pt-BR", "th": "th"}

# 파일 · 배치 · 언어별 (헤드라인, 보조 문장)
SHOTS = [
    ("01-piano.png",     "left-text",  {"ko": ("건반을 누르면<br>오선에 음표가", "음 길이와 쉼표를 고르고 바로 들어요"), "en": ("Press a key,<br>get a note on the staff", "Pick a note length or rest and hear it right away"), "en-GB": ("Press a key,<br>get a note on the staff", "Pick a note length or rest and hear it right away"), "zh-Hans": ("按下琴键，<br>五线谱上就出现音符", "选好时值或休止符，马上就能听到"), "zh-Hant": ("按下琴鍵，<br>五線譜上就出現音符", "選好長度或休止符，馬上就能聽到"), "ja": ("鍵盤を押すと、<br>五線に音符が入る", "音の長さや休符を選んで、すぐ聴ける"), "ru": ("Нажмите клавишу —<br>нота на стане", "Выберите длительность или паузу и сразу услышьте"), "es": ("Pulsa una tecla<br>y la nota va al pentagrama", "Elige duración o silencio y escúchalo al instante"), "de": ("Taste drücken,<br>Note im Notensystem", "Notenlänge oder Pause wählen und sofort hören"), "fr": ("Appuyez sur une touche,<br>la note se pose sur la portée", "Choisissez durée ou silence et écoutez aussitôt"), "it": ("Premi un tasto,<br>la nota va sul pentagramma", "Scegli durata o pausa e ascolta subito"), "pt-BR": ("Toque numa tecla,<br>a nota vai para a pauta", "Escolha a duração ou a pausa e ouça na hora"), "th": ("กดคีย์<br>โน้ตก็ขึ้นบนบรรทัดห้าเส้น", "เลือกความยาวหรือตัวหยุด แล้วฟังได้ทันที")}),
    ("02-playback.png",  "top",        {"ko": ("처음 보는 악보도 소리로 확인해요", "메트로놈에 맞춰 지금 음표를 따라가요"), "en": ("Check a new score by ear", "Follow the sounding note in time with the metronome"), "en-GB": ("Check a new score by ear", "Follow the sounding note in time with the metronome"), "zh-Hans": ("新的乐谱，用耳朵确认", "跟着节拍器，看正在发声的音符"), "zh-Hant": ("新的樂譜，用耳朵確認", "跟著節拍器，看正在發聲的音符"), "ja": ("初見の譜面を、耳で確認", "メトロノームに合わせて、鳴っている音符を追う"), "ru": ("Проверьте новые ноты на слух", "Следите за звучащей нотой в такт метроному"), "es": ("Comprueba una partitura nueva de oído", "Sigue la nota que suena al ritmo del metrónomo"), "de": ("Neue Noten mit dem Gehör prüfen", "Der klingenden Note im Metronomtakt folgen"), "fr": ("Vérifiez une nouvelle partition à l’oreille", "Suivez la note qui sonne, au rythme du métronome"), "it": ("Controlla a orecchio un nuovo spartito", "Segui la nota che suona a tempo di metronomo"), "pt-BR": ("Confira uma partitura nova de ouvido", "Acompanhe a nota que toca no ritmo do metrônomo"), "th": ("ตรวจโน้ตใหม่ด้วยหู", "ตามตัวโน้ตที่กำลังดังตามจังหวะเมโทรนอม")}),
    ("03-dictation.png", "right-text", {"ko": ("계이름을 말하면<br>음표가 돼요", "박에 맞춰 말하면 박자까지 함께 잡혀요"), "en": ("Say note names,<br>get notes", "Speak on the beat and the rhythm is captured too"), "en-GB": ("Say note names,<br>get notes", "Speak on the beat and the rhythm is captured too"), "zh-Hans": ("说出唱名，<br>变成音符", "踩准拍子说，节奏也会一并记录"), "zh-Hant": ("說出唱名，<br>變成音符", "踩準拍子說，節奏也會一併記錄"), "ja": ("階名を言えば、<br>音符になる", "拍に合わせて話せば、リズムまで取り込める"), "ru": ("Назовите ноты —<br>получите ноты на стане", "Говорите в такт — запишется и ритм"), "es": ("Di las notas<br>y se vuelven notas", "Habla al pulso y el ritmo también se registra"), "de": ("Notennamen sprechen,<br>Noten erhalten", "Auf den Schlag sprechen – der Rhythmus wird mit erfasst"), "fr": ("Dites les notes,<br>elles s’écrivent", "Parlez sur le temps, le rythme est saisi aussi"), "it": ("Di’ i nomi delle note<br>e diventano note", "Parla sul battito e viene catturato anche il ritmo"), "pt-BR": ("Diga as notas<br>e viram notas", "Fale no tempo e o ritmo também é registrado"), "th": ("พูดชื่อโน้ต<br>แล้วกลายเป็นโน้ต", "พูดตรงจังหวะ จังหวะก็ถูกจับไปด้วย")}),
    ("04-paste.png",     "dark",       {"ko": ("텍스트 악보를 붙여넣어 오선지를 채워요", "정해진 규칙대로 적은 글이 그대로 음표가 돼요"), "en": ("Paste a text score to fill the staff", "Text written by the rule becomes notes as it is"), "en-GB": ("Paste a text score to fill the staff", "Text written by the rule becomes notes as it is"), "zh-Hans": ("粘贴文字乐谱，填满五线谱", "按规则写成的文字，直接变成音符"), "zh-Hant": ("貼上文字樂譜，填滿五線譜", "依規則寫成的文字，直接變成音符"), "ja": ("テキスト楽譜を貼り付けて五線を埋める", "決まった書式の文章が、そのまま音符に"), "ru": ("Вставьте нотный текст и заполните стан", "Текст по правилу превращается в ноты"), "es": ("Pega una partitura de texto y llena el pentagrama", "Un texto escrito con la regla se convierte en notas"), "de": ("Notentext einfügen und das Notensystem füllen", "Nach Regel geschriebener Text wird zu Noten"), "fr": ("Collez une partition en texte pour remplir la portée", "Un texte écrit selon la règle devient des notes"), "it": ("Incolla uno spartito in testo e riempi il pentagramma", "Un testo scritto con la regola diventa note"), "pt-BR": ("Cole uma partitura em texto e preencha a pauta", "Um texto escrito pela regra vira notas"), "th": ("วางโน้ตแบบข้อความเพื่อเติมบรรทัดห้าเส้น", "ข้อความที่เขียนตามกฎกลายเป็นโน้ตทันที")}),
]

# 색은 헤더·검색 결과 그림(make_creative_assets.py)과 맞춘다.
THEME = dict(bg="linear-gradient(150deg,#5AA6F7 0%,#3B82E6 45%,#2459C4 100%)", ink="#ffffff",
             sub="rgba(255,255,255,.85)", dark_bg="#10213f", dark_ink="#ffffff", dark_sub="#A9C6F2",
             frame="#10213f", rim="#5b7fb8", glow="rgba(90,166,247,.35)")

BASE_CSS = """
* { margin:0; padding:0; box-sizing:border-box; }
html,body { width:%(W)dpx; height:%(H)dpx; overflow:hidden; }
body { background:%(bg)s; font-family:-apple-system, "Apple SD Gothic Neo", "Hiragino Sans", sans-serif; position:relative; }
.headline { font-size:96px; font-weight:800; color:%(ink)s; letter-spacing:-2px; line-height:1.22; text-wrap:balance; }
.sub { font-size:50px; font-weight:500; color:%(sub)s; letter-spacing:-1px; line-height:1.35; text-wrap:balance; }
:lang(ko) .headline, :lang(ko) .sub { word-break:keep-all; }
.phone { background:%(frame)s; border-radius:112px; position:relative; border:3px solid %(rim)s; padding:24px;
  box-shadow: 60px 90px 120px rgba(0,0,0,.24), 20px 30px 50px rgba(0,0,0,.14); }
.phone img { width:100%%; display:block; border-radius:89px; }
"""

LAYOUTS = {
    # 가로 화면 — 헤드라인 위, 기기 아래 블리드
    "top": """
.headline { text-align:center; margin-top:110px; padding:0 120px; font-size:88px; }
.sub { text-align:center; margin-top:30px; font-size:46px; }
.wrap { display:flex; justify-content:center; margin-top:80px; }
.phone { width:1900px; }
""",
    # 왼쪽 글, 오른쪽 기기 (오른쪽 블리드)
    "left-text": """
.headline { position:absolute; left:130px; top:360px; width:800px; font-size:96px; }
.sub { position:absolute; left:134px; top:640px; width:760px; font-size:46px; }
.wrap { position:absolute; left:980px; top:190px; }
.phone { width:1880px; }
""",
    # 왼쪽 기기 (왼쪽 블리드), 오른쪽 글
    "right-text": """
.headline { position:absolute; right:110px; top:360px; width:780px; font-size:96px; }
.sub { position:absolute; right:114px; top:640px; width:760px; font-size:46px; }
.wrap { position:absolute; right:920px; top:230px; }
.phone { width:1740px; }
""",
    "dark": """
body { background:%(dark_bg)s; }
.headline { color:%(dark_ink)s; text-align:center; margin-top:110px; padding:0 120px; font-size:88px; }
.sub { color:%(dark_sub)s; text-align:center; margin-top:30px; font-size:46px; }
.wrap { display:flex; justify-content:center; margin-top:80px; }
.phone { width:1900px; border-color:#5b7fb8; box-shadow: 0 0 160px %(glow)s, 40px 70px 110px rgba(0,0,0,.55); }
""",
}

TEXT_FIRST = '<div class="headline">{h}</div><div class="sub">{s}</div><div class="wrap"><div class="phone"><img src="{img}"></div></div>'
PHONE_FIRST = '<div class="wrap"><div class="phone"><img src="{img}"></div></div><div class="headline">{h}</div><div class="sub">{s}</div>'
HTML = '<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><style>{css}</style></head><body>{body}</body></html>'


def raw_for(lang, fname):
    p = RAW / lang / fname
    return p if p.exists() else RAW / fname


def main(langs):
    tmp = pathlib.Path(tempfile.mkdtemp())
    vals = dict(THEME, W=W, H=H)
    for lang in langs:
        out_dir = OUT / STORE[lang]
        out_dir.mkdir(parents=True, exist_ok=True)
        for fname, layout, texts in SHOTS:
            h, s = texts[lang]
            src = raw_for(lang, fname)
            assert src.exists(), f"원본 없음: {src}"
            tpl = PHONE_FIRST if layout == "text-bottom" else TEXT_FIRST
            css = BASE_CSS % vals + LAYOUTS[layout] % vals if "%(" in LAYOUTS[layout] else BASE_CSS % vals + LAYOUTS[layout]
            html = tmp / f"{lang}-{fname}.html"
            html.write_text(HTML.format(lang=lang, css=css, body=tpl.format(h=h, s=s, img=src.as_uri())), encoding="utf-8")
            out = out_dir / fname
            # Chrome 은 그림을 다 쓰고도 안 끝나거나, 아무것도 안 그리고 끝날 때가 있다.
            # 파일이 생기고 크기가 멈추면 다 된 것으로 보고 닫는다. 세 번까지 한다.
            for _ in range(3):
                out.unlink(missing_ok=True)
                proc = subprocess.Popen([CHROME, "--headless=new", f"--screenshot={out}", f"--window-size={W},{H}",
                                         "--force-device-scale-factor=1", "--hide-scrollbars", "--disable-gpu",
                                         "--no-first-run", "--disable-extensions", "--disable-background-networking",
                                         "--virtual-time-budget=3000", "--allow-file-access-from-files",
                                         f"--user-data-dir={tmp / 'chrome'}", html.as_uri()],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                size, deadline = -1, time.time() + 90
                while time.time() < deadline:
                    time.sleep(1)
                    now = out.stat().st_size if out.exists() else -1
                    if now > 0 and now == size:
                        break
                    if proc.poll() is not None and now <= 0:
                        break
                    size = now
                proc.kill(); proc.wait()
                if out.exists() and out.stat().st_size > 0:
                    break
            else:
                raise SystemExit(f"Chrome 이 그리지 못했다: {out}")
            print("rendered", out.relative_to(ROOT))


if __name__ == "__main__":
    main(sys.argv[1:] or list(STORE))
