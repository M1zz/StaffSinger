// 초견 웹 체험: 두 마디 오선에 음표를 찍고, 카운트인과 메트로놈에 맞춰 들어 본다.
// 규칙은 앱과 같다: 높은음자리표 맨 윗줄 F5 · 가운데 줄 B4 (Clef.treble), 템포 90 · 40~200 (Score · SettingsForm),
// 카운트인 한 마디, 마디 첫 박 강한 클릭 (AudioEngine), 두 마디가 넘치면 넣지 않음 (appendStartRespectingBars).
(() => {
  const root = document.getElementById("demo");
  if (!root) return;
  const T = JSON.parse(root.dataset.text);
  const NS = "http://www.w3.org/2000/svg";
  const LETTERS = ["C", "D", "E", "F", "G", "A", "B"], SEMI = [0, 2, 4, 5, 7, 9, 11];
  const BAR = 4, TOP = 50, GAP = 14, X0 = 96, X1 = 676, BW = (X1 - X0) / (BAR * 2);

  // 윗줄 F5 에서 아래로 몇 칸(반 줄 간격) 내려왔는가 → 음. 앱의 StaffLayout.pitch(forY:) 와 같은 계산.
  const TOP_DIA = 3 + 5 * 7;                       // F5 의 온음계 번호
  const pitch = step => { const d = TOP_DIA - step, o = Math.floor(d / 7); return { d, midi: 12 * (o + 1) + SEMI[d - o * 7] }; };
  const label = step => { const { d } = pitch(step), i = d % 7; return `${T.names ? T.names[i] + " · " : ""}${LETTERS[i]}${Math.floor(d / 7)}`; };
  const LEN = { half: 2, quarter: 1, eighth: 0.5 };

  // 처음에 들어 있는 두 마디: 솔 미미 파 레레 | 도레 미파 솔 솔
  const start = [[6, "quarter"], [8, "eighth"], [8, "eighth"], [7, "quarter"], [9, "eighth"], [9, "eighth"],
                 [10, "eighth"], [9, "eighth"], [8, "eighth"], [7, "eighth"], [6, "quarter"], [6, "quarter"]];
  let notes = [], dur = "quarter", tempo = 90, ghost = null, cursor = 6, playing = false;
  const used = () => notes.reduce((s, n) => s + LEN[n.dur], 0);
  start.forEach(([step, d]) => notes.push({ step, dur: d, beat: used() }));

  root.innerHTML = `
    <div class="sd-stage">
      <svg class="sd-staff" viewBox="0 0 700 150" role="img" tabindex="0" aria-label="${T.staff}"></svg>
      <div class="sd-readout" aria-live="polite"></div>
    </div>
    <div class="sd-controls">
      <div class="sd-group" role="group" aria-label="${T.length}">
        ${["half", "quarter", "eighth"].map(d => `<button type="button" class="chip" data-dur="${d}" aria-pressed="${d === dur}">${T[d]}</button>`).join("")}
      </div>
      <div class="sd-group">
        <button type="button" class="chip" data-act="undo">${T.undo}</button>
        <button type="button" class="chip" data-act="clear">${T.clear}</button>
      </div>
      <div class="sd-group sd-tempo">
        <button type="button" class="chip" data-tempo="-10" aria-label="${T.slower}">−</button>
        <span><b>${tempo}</b> BPM · 4/4</span>
        <button type="button" class="chip" data-tempo="10" aria-label="${T.faster}">+</button>
      </div>
      <button type="button" class="sd-play">${T.play}</button>
    </div>
    <p class="muted small sd-foot">${T.note}</p>`;

  const $ = s => root.querySelector(s);
  const svg = $(".sd-staff"), readout = $(".sd-readout"), playBtn = $(".sd-play");
  const el = (tag, attrs, parent = svg) => { const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]); parent.appendChild(e); return e; };
  const yOf = step => TOP + step * GAP / 2;
  const xOf = beat => X0 + (beat + 0.5) * BW - 12;

  function drawNote(n, cls) {
    const g = el("g", { class: cls }), x = xOf(n.beat), y = yOf(n.step), up = n.step > 4;
    for (let s = n.step <= -2 ? -2 : 10; n.step <= -2 ? s >= n.step : s <= n.step; s += n.step <= -2 ? -2 : 2)
      el("line", { x1: x - 13, x2: x + 13, y1: yOf(s), y2: yOf(s), class: "sd-line" }, g);   // 덧줄
    el("ellipse", { cx: x, cy: y, rx: 8.5, ry: 6, transform: `rotate(-20 ${x} ${y})`,
      class: n.dur === "half" ? "sd-hollow" : "sd-head" }, g);
    const sx = up ? x + 7.5 : x - 7.5, sy = up ? y - 46 : y + 46;
    el("line", { x1: sx, x2: sx, y1: y, y2: sy, class: "sd-stem" }, g);
    n.stem = { x: sx, y: sy, up };
    return g;
  }

  function render() {
    svg.textContent = "";
    for (let i = 0; i < 5; i++) el("line", { x1: 20, x2: X1, y1: TOP + i * GAP, y2: TOP + i * GAP, class: "sd-line" });
    [[20, 1.5], [X0 + BAR * BW, 1.5], [X1 - 4, 1.5], [X1, 4]].forEach(([x, w]) =>
      el("line", { x1: x, x2: x, y1: TOP, y2: TOP + 4 * GAP, class: "sd-line", "stroke-width": w }));
    el("text", { x: 22, y: TOP + 4 * GAP + 14, class: "sd-clef" }).textContent = "𝄞";
    ["4", "4"].forEach((t, i) => (el("text", { x: 68, y: TOP + 26 + i * 28, class: "sd-time" }).textContent = t));
    notes.forEach((n, i) => (n.g = drawNote(n, i === playing ? "sd-note on" : "sd-note")));
    // 8분음표 둘이 한 박에 있으면 잇고(빔), 혼자면 꼬리를 단다.
    notes.forEach((n, i) => {
      if (n.dur !== "eighth") return;
      const m = notes[i + 1], p = notes[i - 1];
      if (m && m.dur === "eighth" && n.beat % 1 === 0 && m.beat === n.beat + 0.5) {
        const up = n.step + m.step > 8, y = up ? Math.min(yOf(n.step), yOf(m.step)) - 46 : Math.max(yOf(n.step), yOf(m.step)) + 46;
        [n, m].forEach(k => { const st = k.g.querySelector(".sd-stem"), x = xOf(k.beat) + (up ? 7.5 : -7.5);
          st.setAttribute("x1", x); st.setAttribute("x2", x); st.setAttribute("y2", y); });
        el("line", { x1: xOf(n.beat) + (up ? 7.5 : -7.5), x2: xOf(m.beat) + (up ? 7.5 : -7.5), y1: y, y2: y, class: "sd-beam" });
      } else if (!(p && p.dur === "eighth" && p.beat % 1 === 0 && n.beat === p.beat + 0.5)) {
        const { x, y, up } = n.stem;
        el("path", { d: `M${x} ${y} q 12 ${up ? 10 : -10} 8 ${up ? 26 : -26}`, class: "sd-flag" }, n.g);
      }
    });
    if (ghost !== null && used() < BAR * 2) drawNote({ step: ghost, dur, beat: used() }, "sd-note ghost");
    root.querySelectorAll("[data-dur]").forEach(b => b.setAttribute("aria-pressed", b.dataset.dur === dur));
    $(".sd-tempo b").textContent = tempo;
    playBtn.textContent = playing === false ? T.play : T.stop;
    playBtn.classList.toggle("hint", !root.dataset.used && playing === false);
  }

  // 소리: 앱은 피아노 음원, 웹은 간단한 합성음. 클릭은 마디 첫 박이 더 높고 크다.
  let ctx;
  const audio = () => { ctx = ctx || new (window.AudioContext || window.webkitAudioContext)(); ctx.resume(); return ctx; };
  function tone(midi, at, len) {
    const c = audio(), o = c.createOscillator(), g = c.createGain();
    o.type = "triangle"; o.frequency.value = 440 * 2 ** ((midi - 69) / 12);
    g.gain.setValueAtTime(0.0001, at); g.gain.exponentialRampToValueAtTime(0.35, at + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, at + Math.max(0.25, len));
    o.connect(g).connect(c.destination); o.start(at); o.stop(at + len + 0.05);
  }
  function click(at, strong) {
    const c = audio(), o = c.createOscillator(), g = c.createGain();
    o.frequency.value = strong ? 1600 : 1000;
    g.gain.setValueAtTime(0.0001, at); g.gain.exponentialRampToValueAtTime(strong ? 0.4 : 0.22, at + 0.002);
    g.gain.exponentialRampToValueAtTime(0.0001, at + 0.05);
    o.connect(g).connect(c.destination); o.start(at); o.stop(at + 0.06);
  }

  let timers = [];
  function stop() { timers.forEach(clearTimeout); timers = []; playing = false; render(); }
  function play() {
    if (!notes.length) return;
    root.dataset.used = "1";
    const c = audio(), spb = 60 / tempo, t0 = c.currentTime + 0.1 + BAR * spb, end = Math.ceil(used() / BAR) * BAR;
    for (let b = 0; b < BAR; b++) click(t0 - (BAR - b) * spb, b === 0);         // 카운트인 한 마디
    for (let b = 0; b < end; b++) click(t0 + b * spb, b % BAR === 0);          // 메트로놈
    playing = -1; render();
    notes.forEach((n, i) => {
      const at = t0 + n.beat * spb;
      tone(pitch(n.step).midi, at, LEN[n.dur] * spb * 0.95);
      timers.push(setTimeout(() => { playing = i; render(); }, (at - c.currentTime) * 1000));
    });
    timers.push(setTimeout(stop, (t0 + end * spb - c.currentTime) * 1000));
  }

  function say(text) { readout.textContent = text; }
  function add(step) {
    const beat = used(), len = LEN[dur], next = (Math.floor(beat / BAR) + 1) * BAR;
    if (beat + len > BAR * 2) return say(T.full);
    if (beat < next && beat + len > next) return say(T.cross);
    notes.push({ step, dur, beat }); root.dataset.used = "1";
    tone(pitch(step).midi, audio().currentTime, 0.4);
    say(`${label(step)} · ${T[dur]}`);
  }

  // 오선을 누른 채 위아래로 움직이면 음이 바뀌며 들리고, 손을 떼면 들어간다 (앱과 같은 방식).
  const stepAt = e => { const r = svg.getBoundingClientRect(), y = (e.clientY - r.top) * 150 / r.height;
    return Math.max(-4, Math.min(12, Math.round((y - TOP) / (GAP / 2)))); };
  svg.addEventListener("pointerdown", e => {
    if (playing !== false) return stop();
    svg.setPointerCapture(e.pointerId); ghost = stepAt(e); tone(pitch(ghost).midi, audio().currentTime, 0.3); say(label(ghost)); render();
  });
  svg.addEventListener("pointermove", e => {
    if (ghost === null) return;
    const s = stepAt(e); if (s === ghost) return;
    ghost = s; tone(pitch(s).midi, audio().currentTime, 0.3); say(label(s)); render();
  });
  svg.addEventListener("pointerup", () => { if (ghost === null) return; const s = ghost; ghost = null; add(s); render(); });
  svg.addEventListener("pointercancel", () => { ghost = null; render(); });
  svg.addEventListener("keydown", e => {
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      e.preventDefault(); cursor = Math.max(-4, Math.min(12, cursor + (e.key === "ArrowUp" ? -1 : 1)));
      ghost = cursor; tone(pitch(cursor).midi, audio().currentTime, 0.3); say(label(cursor)); render();
    } else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); add(cursor); ghost = null; render(); }
  });
  svg.addEventListener("blur", () => { ghost = null; render(); });

  root.addEventListener("click", e => {
    const b = e.target.closest("button"); if (!b) return;
    if (b.dataset.dur) dur = b.dataset.dur;
    if (b.dataset.tempo) tempo = Math.max(40, Math.min(200, tempo + +b.dataset.tempo));
    if (b.dataset.act === "undo") { notes.pop(); say(""); }
    if (b.dataset.act === "clear") { notes = []; say(T.empty); }
    if (b === playBtn) return playing === false ? play() : stop();
    if (playing !== false && (b.dataset.act || b.dataset.tempo)) stop();
    render();
  });

  say(T.hint);
  render();
})();
