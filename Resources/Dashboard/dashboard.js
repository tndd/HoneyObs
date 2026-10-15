'use strict';
(() => {
  const q = selector => document.querySelector(selector);
  const NS = 'http://www.w3.org/2000/svg';
  const map = window.HoneyObsMap;
  const countries = new Map(map.countries.map(country => [country.code, country]));
  let state = { events: [], session: '', active: false }, selected = null, followNewest = true;
  let rejectionCounts = {};
  let seen = new Set(), animations = [], currentSignature = '', totalSeen = null;
  const svg = (name, attributes) => {
    const element = document.createElementNS(NS, name);
    for (const [key, value] of Object.entries(attributes)) element.setAttribute(key, value);
    return element;
  };
  q('#graticule').setAttribute('d', map.graticule);
  for (const country of map.countries) q('#land').append(svg('path', {
    d: country.path, 'data-country': country.code, class: country.code === 'JP' ? 'japan' : ''
  }));
  function action(name) {
    window.webkit?.messageHandlers.honeyobs.postMessage({ action: name });
  }
  q('#local').onclick = () => action('start-local');
  q('#toggle').onclick = () => action(state.active ? 'stop' : 'start-public');
  q('#copy').onclick = () => action('copy-url');
  const date = time => {
    const value = new Date(time);
    return Number.isNaN(value.getTime()) ? '時刻不明' : value.toLocaleString('ja-JP', { hour12: false });
  };
  const clock = time => {
    const value = new Date(time);
    return Number.isNaN(value.getTime()) ? '—' : value.toLocaleTimeString('ja-JP', { hour12: false });
  };
  function route(code) {
    const point = countries.get(code)?.point;
    if (!point) return null;
    const home = map.home;
    if (code === 'JP') return `M ${home[0]} ${home[1]} c -24 -26 24 -26 0 0`;
    return `M ${point[0]} ${point[1]} Q ${(point[0] + home[0]) / 2} ${Math.max(10, Math.min(point[1], home[1]) - Math.min(75, Math.abs(point[0] - home[0]) * .25) - 14)} ${home[0]} ${home[1]}`;
  }
  function cancelAnimations() {
    animations.forEach(id => cancelAnimationFrame(id)); animations = [];
    document.querySelectorAll('.packet').forEach(node => node.remove());
  }
  function pulse(code) {
    if (!state.active || document.hidden || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const d = route(code); if (!d) return;
    const path = svg('path', { d, class: 'transient-route', visibility: 'hidden' });
    const point = svg('circle', { r: 3, class: 'packet' });
    q('#routes').append(path); q('#points').append(point);
    const length = path.getTotalLength(), start = performance.now();
    function step(now) {
      const t = Math.min(1, (now - start) / 1500), at = path.getPointAtLength(t * length);
      point.setAttribute('cx', at.x); point.setAttribute('cy', at.y);
      if (t < 1 && state.active) animations.push(requestAnimationFrame(step));
      else { path.remove(); point.remove(); }
    }
    animations.push(requestAnimationFrame(step));
  }
  function drawMap() {
    cancelAnimations(); q('#routes').replaceChildren(); q('#points').replaceChildren();
    const event = state.events.find(item => item.id === selected);
    const recentCodes = [...new Set(state.events.filter(item => !item.test).map(item => item.countryCode))].slice(0, 12);
    for (const code of recentCodes) {
      const d = route(code); if (d && code !== event?.countryCode) q('#routes').append(svg('path', { d, class: 'context-route' }));
    }
    const d = event && route(event.countryCode);
    if (d) {
      q('#routes').append(svg('path', { d, class: 'route', 'data-selected': event.id }));
      const point = countries.get(event.countryCode).point;
      q('#points').append(svg('circle', { cx: point[0], cy: point[1], r: 4, class: 'origin' }));
    }
    q('#points').append(svg('circle', { cx: map.home[0], cy: map.home[1], r: 5, class: 'home' }));
    document.querySelectorAll('#land path').forEach(node => node.classList.toggle('selected-country', node.dataset.country === event?.countryCode));
    const missing = state.events.filter(item => !countries.get(item.countryCode)).length;
    q('#map-note').textContent = event && !d ? 'このアクセスは地図位置なし · 一覧に保持' : `国単位の推定 · 地図位置なし ${missing} 件`;
    placeLabel();
    if (state.exercise) { q('#map-note').textContent = '通信元はlocalhost · 位置の演出なし'; q('#home-label').textContent = 'おとりVM · 表示上の観測点'; }
  }
  function details() {
    const event = state.events.find(item => item.id === selected);
    q('#country').textContent = event?.country || 'アクセスを選択';
    q('#ip').textContent = event?.ip || '—';
    q('#time').textContent = event ? date(event.time) : '—';
    q('#request').textContent = event ? `${event.method} ${event.path}` : '—';
    q('#path-note').hidden = !event?.pathTruncated;
    q('#path-note').textContent = event?.pathTruncated ? `パスを省略表示 · 元 ${event.pathBytes} バイト · SHA-256 ${event.pathSHA256}` : '';
    q('#response').textContent = event ? `${event.status} · 模擬サービスの応答${event.test ? '（確認用）' : ''}` : '—';
    q('#location').textContent = state.exercise ? 'localhostからの試験 · ヘッダーのIPを地理推定に使いません' : !event ? '—' : !event.countryCode ? '位置不明（未取得・予約IP・DB未収録）' :
      countries.has(event.countryCode) ? `${event.country} · 国単位の推定` : `${event.country} · 地図の代表位置なし`;
  }
  function renderEvents() {
    const list = q('#events'), scroll = list.scrollTop;
    const focusedID = document.activeElement?.closest?.('.event')?.dataset.id;
    list.replaceChildren();
    for (const event of state.events) {
      const li = document.createElement('li'), button = document.createElement('button');
      button.className = 'event'; button.dataset.id = event.id; button.dataset.test = String(event.test);
      button.setAttribute('aria-pressed', String(event.id === selected));
      button.setAttribute('aria-label', `${event.country} ${event.method} ${event.path} ${event.test ? '確認用' : ''}`);
      for (const [className, text] of [['country', event.country], ['time', clock(event.time)], ['path', `${event.method} ${event.path}`], ['code', String(event.status)]]) {
        const span = document.createElement('span'); span.className = className; span.textContent = text;
        if (className === 'country' && event.test) {
          const badge = document.createElement('span'); badge.className = 'test'; badge.textContent = '確認用'; span.append(badge);
        }
        button.append(span);
      }
      button.onclick = () => {
        selected = event.id; followNewest = event.id === state.events[0]?.id;
        list.querySelectorAll('button').forEach(node => node.setAttribute('aria-pressed', String(node.dataset.id === selected)));
        details(); drawMap(); pulse(event.countryCode);
      };
      li.append(button); list.append(li);
    }
    list.scrollTop = followNewest ? 0 : scroll;
    if (focusedID) [...list.querySelectorAll('button')].find(node => node.dataset.id === focusedID)?.focus({ preventScroll: true });
    q('#empty').hidden = state.events.length > 0;
    q('#empty').textContent = state.active ? '受信を待っています。ローカル検証では外部へ公開されません。' : '一時公開を開始すると、ここに受信したアクセスが表示されます。';
    q('#retained').textContent = `${state.events.length} / 128 件`;
  }
  function placeLabel() {
    const canvas = q('.map'), matrix = canvas.getScreenCTM(); if (!matrix) return;
    const point = canvas.createSVGPoint(); point.x = map.home[0]; point.y = map.home[1];
    const screen = point.matrixTransform(matrix), bounds = q('.map-wrap').getBoundingClientRect();
    q('#home-label').style.left = `${screen.x - bounds.left}px`;
    q('#home-label').style.top = `${screen.y - bounds.top + 13}px`;
  }
  window.honeyobs = {
    update(next) {
      const reset = state.session !== next.session;
      if (reset) { selected = null; followNewest = true; seen = new Set(); currentSignature = ''; totalSeen = null; rejectionCounts = {}; q('#shield').hidden = true; }
      const fresh = next.events.filter(event => !seen.has(event.id));
      state = next;
      const ids = new Set(next.events.map(event => event.id));
      if (followNewest || !ids.has(selected)) selected = next.events[0]?.id ?? null;
      seen = ids;
      document.body.dataset.active = String(next.active); document.body.dataset.error = String(['エラー', '停止失敗'].includes(next.phase));
      q('#phase').textContent = next.phase;
      q('#url').textContent = next.active && next.url ? next.url : '公開URLなし';
      q('#engine-detail').textContent = next.detail;
      q('#toggle').textContent = next.active ? '停止' : '一時公開を開始';
      q('#toggle').disabled = !next.active && !next.canStart; q('#local').disabled = !next.canStart;
      q('#copy').hidden = !(next.active && next.url);
      q('#exercise-panel').hidden = !next.exercise;
      q('#local').hidden = Boolean(next.exercise);
      if (next.exercise) {
        const exercise = next.exercise;
        q('#exercise-panel').dataset.sequence = String(exercise.sequence ?? 0);
        q('#exercise-scenario').textContent = exercise.scenario ?? '準備中';
        q('#exercise-stage').textContent = exercise.stage ?? '待機';
        q('#exercise-response').textContent = exercise.response ?? '未受信';
        q('#exercise-record').textContent = exercise.record ?? '未確認';
        q('#toggle').textContent = '自己ペネを中止';
        q('#toggle').disabled = !next.active || Boolean(exercise.finished);
        q('#copy').hidden = true;
      }
      q('#count').textContent = next.total;
      const observation = next.observation ?? {};
      const reasons = { http_400: 'HTTP拒否400', http_431: 'ヘッダー上限', http_505: 'HTTP版不正', http_incomplete: 'HTTP未完了', http_timeout: 'HTTP読取期限', connection_limit: '接続数上限', guest_connect: 'VM接続失敗', relay_timeout: '中継期限', relay_input_limit: '中継入力上限' };
      const rejected = Object.entries(observation.rejections ?? {}).map(([key, value]) => `${reasons[key] ?? 'その他'} ${value.count}件`).join(' / ');
      q('#observation-status').textContent = `保存 ${observation.retained ?? next.events.length} / 4096件 · 取得前の欠落 ${observation.uncollected ?? 0}件 · 保存上限による破棄 ${observation.evicted ?? 0}件 · 取得待ち ${observation.pending ?? 0}件${rejected ? ` · HTTP処理前／入口の拒否: ${rejected}` : ''}`;
      const increments = Object.entries(observation.rejections ?? {}).filter(([key, value]) => value.count > (rejectionCounts[key] ?? 0));
      let shieldTitle = '', shieldNote = '', shieldKind = 'received';
      if (increments.length) {
        shieldTitle = '拒否を記録'; shieldKind = 'reject';
        shieldNote = increments.map(([key, value]) => `${reasons[key] ?? 'その他'} +${value.count - (rejectionCounts[key] ?? 0)}件`).join(' / ');
      } else if (fresh.length) {
        const event = fresh[0];
        shieldKind = [400,401,403,413,431,505].includes(event.status) ? 'reject' : 'received';
        shieldTitle = `HTTP ${event.status} · ${event.status === 401 ? '認証失敗' : shieldKind === 'reject' ? '拒否' : '受信'}`;
        shieldNote = `イベント ${fresh.length}件を取得`;
      }
      rejectionCounts = Object.fromEntries(Object.entries(observation.rejections ?? {}).map(([key,value]) => [key,value.count]));
      if (next.active && shieldTitle) {
        q('#shield').hidden = false; q('#shield').dataset.kind = shieldKind;
        q('#shield-title').textContent = shieldTitle; q('#shield-note').textContent = shieldNote;
        q('#shield').classList.remove('pulse');
        if (!document.hidden && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
          void q('#shield').offsetWidth; q('#shield').classList.add('pulse');
        }
      }
      if (!next.active) q('#shield').classList.remove('pulse');
      q('#vm-status').textContent = next.active ? '内蔵VM：動作中 · 受信確認 約1秒ごと' :
        (next.shutdownComplete ?? next.canStart) ? '内蔵VM：停止確認済み' : '内蔵VM：停止未確認';
      q('#geo-status').textContent = next.geoAvailable ? next.geoEdition : 'GeoIPを読み込めません（位置不明として表示）';
      const signature = JSON.stringify([next.session, next.active, next.events]);
      if (signature !== currentSignature) {
        currentSignature = signature; renderEvents(); details(); drawMap();
        fresh.filter(event => !event.test).slice(0, 8).forEach(event => pulse(event.countryCode));
      }
      if (totalSeen !== next.total) q('#announcement').textContent = `受信 ${next.total} 件`;
      totalSeen = next.total;
    }
  };
  new ResizeObserver(placeLabel).observe(q('.map'));
  document.addEventListener('visibilitychange', () => { if (document.hidden) cancelAnimations(); });
  drawMap(); action('ready');
})();
