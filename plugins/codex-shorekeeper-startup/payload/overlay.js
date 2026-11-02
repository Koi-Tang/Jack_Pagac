(() => {
  'use strict';
  const id = 'shorekeeper-codex-startup';
  if (document.getElementById(id)) return { alreadyActive: true };
  if (!document.documentElement) return { installed: false, reason: 'document-not-ready' };
  const mediaUrl = __MEDIA_DATA_URL__;
  const posterUrl = __POSTER_DATA_URL__;
  const host = document.createElement('div');
  host.id = id;
  host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;isolation:isolate;display:block;';
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `<style>
    :host{all:initial;color:#e4fcff;font-family:"Segoe UI","Microsoft YaHei UI","Microsoft YaHei",sans-serif}
    *{box-sizing:border-box}button{font:inherit;color:inherit}
    .scene{position:absolute;inset:0;overflow:hidden;background:#02080f;opacity:0;will-change:clip-path,opacity}
    .scene.prepared,.scene.ready{opacity:1}
    .portrait{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;object-position:68% center;filter:saturate(1.03) brightness(.96)}
    .shade{position:absolute;inset:0;background:linear-gradient(90deg,rgba(2,8,15,.98) 0%,rgba(2,8,15,.84) 21%,rgba(2,8,15,.3) 45%,transparent 70%),linear-gradient(0deg,rgba(0,5,12,.75),transparent 30%,transparent 86%,rgba(0,5,12,.15))}
    .glow{position:absolute;width:42vw;height:42vw;left:-20vw;top:22%;border-radius:50%;background:radial-gradient(ellipse,rgba(32,177,210,.11),transparent 67%);filter:blur(24px)}
    .frame{position:absolute;inset:4.7% 4.5%;border-top:1px solid rgba(149,227,244,.13);border-bottom:1px solid rgba(149,227,244,.13);pointer-events:none}
    .identity{position:absolute;top:10%;left:7.2%;display:flex;align-items:center;gap:16px;opacity:0;animation:rise .55s .08s both}
    .sigil{width:58px;height:58px;filter:drop-shadow(0 0 9px #6ae4ff5c)}
    .eyebrow{font-size:9px;letter-spacing:.35em;color:#74a4b4;margin-bottom:7px}.name{font-family:"Microsoft YaHei UI",sans-serif;font-size:clamp(15px,1.55vw,24px);font-weight:300;letter-spacing:.2em}
    .copy{position:absolute;left:7.5%;top:42%;width:47%;transform:translateY(-4%)}
    h1{font-size:clamp(58px,8.2vw,142px);font-weight:650;letter-spacing:-.055em;line-height:1.05;margin:0 0 22px;color:#d9ffff;background:linear-gradient(110deg,#f1fffc 10%,#b4f4f1 45%,#5dc9ee 92%);background-clip:text;-webkit-background-clip:text;-webkit-text-fill-color:transparent;opacity:0;animation:rise .55s .45s both}
    .rule{width:clamp(120px,20vw,350px);height:1px;transform-origin:left;background:linear-gradient(90deg,#b0f1f0a0,#76c8e000);animation:line .7s .2s both}
    .welcome{margin-top:18px;font-size:clamp(15px,1.85vw,30px);font-weight:300;letter-spacing:.065em;opacity:0;animation:rise .5s 1.35s both}
    .translation{margin-top:11px;font-size:clamp(8px,.68vw,11px);letter-spacing:.25em;color:#7592a2;opacity:0;animation:rise .5s 1.48s both}
    .orbit{position:absolute;left:25%;top:20%;width:52%;height:60%;border:1px solid rgba(137,225,247,.1);border-radius:50%;transform:rotate(-27deg);mask-image:linear-gradient(90deg,transparent 10%,#000 45%,transparent 90%);animation:breathe 5s ease-in-out infinite;pointer-events:none}
    .dust{position:absolute;inset:0;pointer-events:none}.dust i{position:absolute;width:2px;height:2px;background:#bdf9ff;border-radius:50%;box-shadow:0 0 7px #9becff;animation:float 7s linear infinite}
    .footer{position:absolute;left:7.5%;right:7.5%;bottom:8.7%;display:flex;align-items:center;justify-content:space-between;gap:14px;opacity:0;animation:rise .5s .4s both}
    .credit{font-size:10px;letter-spacing:.16em;color:#7f9da9}.skip{border:0;padding:12px 0 12px 16px;background:transparent;cursor:pointer;color:#95acb5;font-size:11px;letter-spacing:.06em}.skip:hover,.skip:focus-visible{color:#e7ffff;outline:none;text-shadow:0 0 10px #b6f9ff}.key{border:1px solid #6c8c9d59;padding:2px 5px;border-radius:3px;margin-right:7px;font-size:9px}
    .progress{position:absolute;bottom:0;left:0;height:2px;width:100%;background:#14252f70}.progress::after{content:"";display:block;height:100%;width:100%;transform:scaleX(0);transform-origin:left;background:linear-gradient(90deg,#244457,#8ee9f2);animation:progress 5s linear both}
    .handoff{position:absolute;height:1px;background:linear-gradient(90deg,transparent,#bcffff,transparent);box-shadow:0 0 18px 3px #6bddf580;opacity:0;pointer-events:none;transform-origin:center}
    .scene:not(.ready) *{animation-play-state:paused}
    @keyframes rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
    @keyframes line{from{transform:scaleX(0)}to{transform:scaleX(1)}}@keyframes progress{to{transform:scaleX(1)}}
    @keyframes drift{from{transform:scale(1.05) translateX(1%)}to{transform:scale(1.015) translateX(0)}}
    @keyframes breathe{50%{opacity:.25}}@keyframes float{0%{opacity:0;transform:translate(0,24px)}25%{opacity:.6}75%{opacity:.3}100%{opacity:0;transform:translate(-30px,-48px)}}
    @media(max-width:600px){.identity{left:7%;top:12%;gap:10px}.sigil{width:40px;height:40px}.copy{top:46%;width:75%}h1{font-size:64px}.welcome{font-size:17px}.portrait{object-position:77% center}.shade{background:linear-gradient(90deg,#02080fee,rgba(2,8,15,.55) 50%,#02080f33),linear-gradient(0deg,#02080f,transparent 50%)}.credit{font-size:8px}.footer{bottom:8%}}
    @media(prefers-reduced-motion:reduce){*,*::after{animation-duration:.01ms!important;animation-delay:0s!important}.scene,.scene.leave{transition-duration:.15s}.portrait{transform:none}}
  </style>
  <section class="scene" aria-label="守岸人 Codex 启动动画">
    <video class="portrait" muted playsinline preload="auto"></video><div class="shade"></div><div class="glow"></div><div class="orbit"></div><div class="frame"></div><div class="dust"></div>
    <div class="identity"><svg class="sigil" viewBox="0 0 80 80" fill="none" aria-hidden="true"><path d="M40 4 50 29 76 40 51 50 40 76 29 51 4 40 29 29Z" stroke="#d8fbff" stroke-width="1.6"/><path d="m40 17 13 36H27ZM14 58 40 8 66 58Z" stroke="#c3f1ff" stroke-width="1"/><path d="m18 20 45 5-5 39-39-6Z" stroke="#7ccfef" stroke-width=".8"/><path d="m40 29 10 11-10 11-10-11Z" fill="#d0f9ff"/><circle cx="40" cy="40" r="4" fill="#061824"/></svg><div><div class="eyebrow">THE BLACK SHORES</div><div class="name">黑海岸 · 守岸人</div></div></div>
    <div class="copy"><h1>Codex</h1><div class="rule"></div><div class="welcome">欢迎回来，漂泊者。</div><div class="translation">WELCOME BACK, ROVER.</div></div>
    <div class="footer"><span class="credit">CODEX × 鸣潮</span><button class="skip" title="跳过动画，进入 Codex"><span class="key">ESC</span>进入 Codex <span aria-hidden="true">↗</span></button></div><div class="progress"></div>
  </section><div class="handoff"></div>`;
  const scene = root.querySelector('.scene');
  const video = root.querySelector('video');
  video.muted = true;
  video.src = mediaUrl;
  if (posterUrl) video.poster = posterUrl;
  let seed = 281;
  for (let i = 0; i < 28; i++) {
    seed = (seed * 16807) % 2147483647;
    const star = document.createElement('i');
    star.style.cssText = `left:${(seed % 930) / 10}%;top:${(seed % 870) / 10 + 5}%;animation-delay:-${i * .29}s;opacity:${.15 + i % 4 * .12}`;
    root.querySelector('.dust').appendChild(star);
  }
  const deferred = window.__SHOREKEEPER_DEFER_REVEAL__ === true;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const pageRoot = document.getElementById('root') || [...(document.body?.children || [])].find(el => el.tagName === 'DIV' && el.id !== id);
  const pageComputed = pageRoot ? getComputedStyle(pageRoot) : null;
  const pageEnd = pageComputed ? { transform: pageComputed.transform, filter: pageComputed.filter, opacity: pageComputed.opacity } : null;
  const pageStart = { transform: 'translateY(12px) scale(.978)', filter: reduced ? 'none' : 'blur(7px)', opacity: .22 };
  const animations = [];
  let pageHold;
  let finished = false, disposed = false, started = false, starting = false, ready = false, cancelled = false;
  let startedAt = 0;
  const timers = [];
  const later = (fn, ms) => { const t = setTimeout(fn, ms); timers.push(t); return t; };
  function targetRect() {
    const candidates = [...document.querySelectorAll('textarea,[contenteditable="true"],[role="textbox"]')];
    for (const el of candidates) {
      if (host.contains(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.width > 180 && r.height > 18 && r.top > 0 && r.bottom < innerHeight + 20) {
        const container = el.closest('form')?.getBoundingClientRect();
        return container && container.height < innerHeight * .4 && container.width > r.width ? container : r;
      }
    }
    return { left: innerWidth * .24, right: innerWidth * .82, top: innerHeight * .67, height: 74 };
  }
  function dispose() {
    if (disposed) return;
    disposed = true;
    video.pause(); video.removeAttribute('src'); video.load();
    document.removeEventListener('keydown', onKey, true);
    document.removeEventListener('shorekeeper-startup-visible', begin);
    document.removeEventListener('shorekeeper-startup-cancel', cancel);
    timers.forEach(clearTimeout); animations.forEach(a => a.cancel()); pageHold?.cancel();
    host.remove();
    document.dispatchEvent(new CustomEvent('shorekeeper-startup-ended', { detail: { elapsedMs: startedAt ? performance.now() - startedAt : 0, started, cancelled, version: '3.0.0' } }));
  }
  function cancel() {
    cancelled = true;
    dispose();
  }
  function fail(code) {
    if (disposed) return;
    host.setAttribute('data-error', code);
    document.dispatchEvent(new CustomEvent('shorekeeper-startup-failed', { detail: { code } }));
    cancel();
  }
  function finish(fast = false) {
    if (finished || disposed) return;
    finished = true;
    host.setAttribute('data-stage', 'handoff');
    const duration = fast || reduced ? 240 : 1200;
    const r = targetRect(), w = innerWidth, h = innerHeight;
    const cy = Math.max(40, Math.min(h - 40, r.top + r.height / 2));
    const left = Math.max(16, r.left - 14), right = Math.max(16, w - r.right - 14);
    const cut = size => `inset(${Math.max(0, cy - size)}px ${right}px ${Math.max(0, h - cy - size)}px ${left}px round ${Math.min(size, 18)}px)`;
    animations.push(scene.animate([
      { clipPath: 'inset(0px 0px 0px 0px round 0px)', opacity: 1, offset: 0 },
      { clipPath: cut(38), opacity: 1, offset: .64 },
      { clipPath: cut(1), opacity: .7, offset: .9 },
      { clipPath: cut(1), opacity: 0, offset: 1 }
    ], { duration, easing: 'cubic-bezier(.65,0,.22,1)', fill: 'both' }));
    root.querySelectorAll('.identity,.copy,.footer,.frame').forEach(el => animations.push(el.animate([
      { opacity: 1, transform: 'translateY(0px)' }, { opacity: 0, transform: 'translateY(-18px)' }
    ], { duration: duration * .48, easing: 'cubic-bezier(.22,1,.36,1)', fill: 'forwards' })));
    const beam = root.querySelector('.handoff');
    beam.style.cssText = `left:${left}px;right:${right}px;top:${cy}px`;
    animations.push(beam.animate([
      { opacity: 0, transform: 'scaleX(.4)', offset: 0 },
      { opacity: 0, transform: 'scaleX(.65)', offset: .5 },
      { opacity: .9, transform: 'scaleX(1)', offset: .78 },
      { opacity: 0, transform: 'scaleX(.96)', offset: 1 }
    ], { duration, fill: 'both', easing: 'ease-out' }));
    pageHold?.cancel();
    if (pageRoot?.isConnected && pageEnd) animations.push(pageRoot.animate([pageStart, pageEnd], { duration, easing: 'cubic-bezier(.22,1,.36,1)', fill: 'both' }));
    later(dispose, duration);
  }
  function onKey(e) {
    if (['Escape', 'Enter', ' ', 'Spacebar'].includes(e.key)) {
      e.preventDefault(); e.stopPropagation();
      if (started) finish(true); else cancel();
    }
  }
  async function begin(event) {
    if (started || starting || disposed || !ready || document.visibilityState !== 'visible') return;
    if (deferred && event?.detail?.foregroundConfirmed !== true) return;
    starting = true;
    try {
      if (video.currentTime > .025) {
        video.pause();
        await new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('rewind-timeout')), 1200);
          video.addEventListener('seeked', () => { clearTimeout(timer); resolve(); }, { once: true });
          video.currentTime = 0;
        });
      }
      if (disposed || document.visibilityState !== 'visible') { starting = false; return; }
      await video.play();
    } catch { starting = false; fail('media-start-failed'); return; }
    if (disposed || document.visibilityState !== 'visible') { video.pause(); starting = false; return; }
    started = true; startedAt = performance.now();
    host.setAttribute('data-stage', 'playing');
    host.setAttribute('data-started-at', String(startedAt));
    scene.classList.add('ready');
    if (pageRoot?.isConnected && pageEnd) pageHold = pageRoot.animate([pageStart, pageStart], { duration: 6000, fill: 'both' });
    document.dispatchEvent(new CustomEvent('shorekeeper-startup-started', { detail: { mediaTime: video.currentTime, startedAt, version: '3.0.0' } }));
    later(() => finish(false), 3800);
    later(dispose, 5000);
  }
  function markReady() {
    if (ready || disposed) return;
    video.pause();
    if (video.readyState < 2 || video.currentTime > .025) { fail('media-first-frame-not-ready'); return; }
    ready = true;
    host.setAttribute('data-stage', 'prepared');
    host.setAttribute('data-ready', 'true');
    scene.classList.add('prepared');
    document.dispatchEvent(new CustomEvent('shorekeeper-startup-ready'));
    if (!deferred) begin();
  }
  root.querySelector('.skip').addEventListener('click', () => started ? finish(true) : cancel());
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('shorekeeper-startup-visible', begin);
  document.addEventListener('shorekeeper-startup-cancel', cancel);
  document.documentElement.appendChild(host);
  video.addEventListener('loadeddata', markReady, { once: true });
  video.addEventListener('error', () => fail('media-decode-failed'), { once: true });
  video.load();
  later(() => { if (!ready) fail('media-prepare-timeout'); }, 8000);
  later(() => { if (!started) cancel(); }, 60000);
  return { installed: true, durationMs: 5000, media: 'full-opening-motion', version: '3.0.0' };
})()
