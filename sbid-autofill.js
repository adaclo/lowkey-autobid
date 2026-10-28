/*!
 * sbid-autofill — rellena las activitats diàries i els informes periòdics de sBID.
 * MIT License. Pega este fichero entero en la consola del navegador con tu sesión
 * de sBID abierta (https://www.empresaiformacio.org/sBid). No maneja contraseñas.
 */
(function () {
  'use strict';

  /* ------------------------------------------------------------------ *
   *  Lógica pura (se prueba con `npm test`)
   * ------------------------------------------------------------------ */

  const QUARTER = 0.25;

  function hashSeed(str) {
    let h = 1779033703 ^ str.length;
    for (let i = 0; i < str.length; i++) {
      h = Math.imul(h ^ str.charCodeAt(i), 3432918353);
      h = (h << 13) | (h >>> 19);
    }
    return h >>> 0;
  }

  function mulberry32(a) {
    return function () {
      let t = (a += 0x6d2b79f5);
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function pickWeighted(rng, list) {
    const sum = list.reduce((t, a) => t + a.weight, 0);
    let r = rng() * sum;
    for (const a of list) {
      r -= a.weight;
      if (r < 0) return a;
    }
    return list[list.length - 1];
  }

  /**
   * Reparte `total` horas entre las actividades de `acts` ([{id, weight}]).
   * Todo en múltiplos de 15 min. Devuelve {id: horas}.
   * opts: {total, minBlock, kMin, kMax, maxPerAct}
   */
  function distribute(rng, acts, opts) {
    const pool = acts.filter((a) => a.weight > 0);
    const total = Math.round(opts.total / QUARTER);
    if (!pool.length || total <= 0) return {};

    const minB = Math.min(total, Math.max(1, Math.round((opts.minBlock || QUARTER) / QUARTER)));
    const cap = Math.round((opts.maxPerAct || opts.total) / QUARTER);
    const kMax = Math.max(1, Math.min(opts.kMax || 3, pool.length, Math.floor(total / minB)));
    const kMin = Math.max(1, Math.min(opts.kMin || 1, kMax));
    const k = kMin + Math.floor(rng() * (kMax - kMin + 1));

    const left = pool.slice();
    const chosen = [];
    while (chosen.length < k) {
      const a = pickWeighted(rng, left);
      left.splice(left.indexOf(a), 1);
      chosen.push(a);
    }

    const q = {};
    chosen.forEach((a) => (q[a.id] = minB));
    let rest = total - minB * k;
    while (rest > 0) {
      const unit = rest >= 2 ? 2 : 1; // bloques de 30 min mientras se pueda
      const cands = chosen.filter((a) => q[a.id] + unit <= cap);
      if (!cands.length) break;
      q[pickWeighted(rng, cands).id] += unit;
      rest -= unit;
    }

    const out = {};
    Object.keys(q).forEach((id) => (out[id] = q[id] * QUARTER));
    return out;
  }

  function parseDate(text) {
    const m = /(\d{2})\/(\d{2})\/(\d{4})/.exec(text || '');
    return m ? new Date(+m[3], +m[2] - 1, +m[1]) : null;
  }

  function isWeekend(d) {
    return d.getDay() === 0 || d.getDay() === 6;
  }

  function pickBestRating(options) {
    const real = options.filter((o) => o.value !== '');
    const best = real.find((o) => /molt adequada|muy adecuada|very adequate|excel/i.test(o.text));
    return (best || real[real.length - 1] || {}).value;
  }

  function norm(s) {
    return String(s).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  }

  const pure = { hashSeed, mulberry32, distribute, parseDate, isWeekend, pickBestRating, norm };
  if (typeof module !== 'undefined' && module.exports) module.exports = pure;
  if (typeof window === 'undefined' || !window.document) return;

  /* ------------------------------------------------------------------ *
   *  Textos
   * ------------------------------------------------------------------ */

  const I18N = {
    es: {
      title: 'sBID autofill',
      scan: 'Leer actividades',
      hours: 'Horas por día',
      minBlock: 'Bloque mínimo (h)',
      kMin: 'Actividades/día (mín)',
      kMax: 'Actividades/día (máx)',
      seed: 'Semilla (mismo valor = mismo reparto)',
      before: 'No tocar días desde',
      weekends: 'Saltar fines de semana',
      reports: 'Rellenar informes periódicos',
      rating: 'Valoración en informes',
      auto: 'Automática (la máxima)',
      dry: 'Simulación (no guarda nada)',
      run: 'Ejecutar',
      stop: 'Parar',
      kw: 'Palabras clave (coma)',
      kwBtn: 'Marcar por palabras',
      all: 'Todas',
      none: 'Ninguna',
      acts: 'Actividades y peso',
      needScan: 'Primero pulsa «Leer actividades».',
      noForm: 'No encuentro ningún formulario de actividad para leer.',
      scanned: (n, max) => `${n} actividades leídas. Máximo de horas/día: ${max}.`,
      nothing: 'No hay nada pendiente.',
      confirm: (n, h) =>
        `Se van a GUARDAR datos reales en sBID (${n} tareas pendientes). Horas por día: ${h}. ¿Continuar?`,
      day: 'día',
      report: 'informe',
      skipped: 'saltado',
      done: 'Terminado.',
      stopped: 'Parado.',
      stuck: 'El servidor no ha aceptado el guardado; paro aquí.',
      noActs: 'Marca al menos una actividad.',
    },
    ca: {
      title: 'sBID autofill',
      scan: 'Llegir activitats',
      hours: 'Hores per dia',
      minBlock: 'Bloc mínim (h)',
      kMin: 'Activitats/dia (mín)',
      kMax: 'Activitats/dia (màx)',
      seed: 'Llavor (mateix valor = mateix repartiment)',
      before: 'No tocar dies a partir de',
      weekends: 'Saltar caps de setmana',
      reports: 'Omplir informes periòdics',
      rating: 'Valoració als informes',
      auto: 'Automàtica (la màxima)',
      dry: 'Simulació (no desa res)',
      run: 'Executar',
      stop: 'Aturar',
      kw: 'Paraules clau (coma)',
      kwBtn: 'Marcar per paraules',
      all: 'Totes',
      none: 'Cap',
      acts: 'Activitats i pes',
      needScan: 'Primer prem «Llegir activitats».',
      noForm: 'No trobo cap formulari d’activitat per llegir.',
      scanned: (n, max) => `${n} activitats llegides. Màxim d’hores/dia: ${max}.`,
      nothing: 'No hi ha res pendent.',
      confirm: (n, h) =>
        `Es DESARAN dades reals a sBID (${n} tasques pendents). Hores per dia: ${h}. Continuar?`,
      day: 'dia',
      report: 'informe',
      skipped: 'saltat',
      done: 'Acabat.',
      stopped: 'Aturat.',
      stuck: 'El servidor no ha acceptat el desat; paro aquí.',
      noActs: 'Marca almenys una activitat.',
    },
    en: {
      title: 'sBID autofill',
      scan: 'Scan activities',
      hours: 'Hours per day',
      minBlock: 'Min block (h)',
      kMin: 'Activities/day (min)',
      kMax: 'Activities/day (max)',
      seed: 'Seed (same value = same split)',
      before: 'Do not touch days from',
      weekends: 'Skip weekends',
      reports: 'Fill periodic reports',
      rating: 'Report rating',
      auto: 'Auto (highest)',
      dry: 'Dry run (saves nothing)',
      run: 'Run',
      stop: 'Stop',
      kw: 'Keywords (comma)',
      kwBtn: 'Select by keywords',
      all: 'All',
      none: 'None',
      acts: 'Activities and weight',
      needScan: 'Press “Scan activities” first.',
      noForm: 'Could not find an activity form to scan.',
      scanned: (n, max) => `${n} activities read. Max hours/day: ${max}.`,
      nothing: 'Nothing pending.',
      confirm: (n, h) =>
        `This will SAVE real data in sBID (${n} pending tasks). Hours per day: ${h}. Continue?`,
      day: 'day',
      report: 'report',
      skipped: 'skipped',
      done: 'Finished.',
      stopped: 'Stopped.',
      stuck: 'The server did not accept the save; stopping here.',
      noActs: 'Select at least one activity.',
    },
  };
  const lang = (navigator.language || 'en').slice(0, 2);
  const t = I18N[lang] || I18N.en;

  /* ------------------------------------------------------------------ *
   *  Acceso a sBID
   * ------------------------------------------------------------------ */

  const BASE = '/' + location.pathname.split('/')[1] + '/modules/';
  const DAY_PATH = 'ActivitatFct';
  const REPORT_PATH = 'ActivitatValoracioFct';

  async function getDoc(url) {
    const r = await fetch(url, { credentials: 'include' });
    return new DOMParser().parseFromString(await r.text(), 'text/html');
  }

  async function postForm(path, params) {
    const r = await fetch(BASE + path, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: params.toString(),
    });
    await r.text();
    return r.status;
  }

  async function getAgenda() {
    const doc = await getDoc(BASE + 'Agenda?moduleaction=show&clearBackStack=true');
    const box = doc.querySelector('#collapse1') || doc;
    const items = [...box.querySelectorAll('li a')]
      .map((a) => {
        const href = a.getAttribute('href') || '';
        const text = a.textContent.replace(/\s+/g, ' ').trim();
        const kind = href.includes(REPORT_PATH) ? 'report' : href.includes(DAY_PATH) ? 'day' : 'other';
        return { href, text, kind, date: parseDate(text) };
      })
      .filter((x) => x.kind !== 'other');
    const badge = doc.querySelector('#heading1 .badge');
    const anyDay = [...doc.querySelectorAll('a')]
      .map((a) => a.getAttribute('href') || '')
      .find((h) => h.includes(DAY_PATH + '?moduleaction=show'));
    return { items, count: badge ? badge.textContent.trim() : String(items.length), anyDay };
  }

  /** Lee un formulario de actividad: actividades (select inp_*), máximo diario, etc. */
  function readDayForm(doc) {
    const form = doc.getElementById('workingForm');
    if (!form) return null;
    const acts = [];
    const tw = doc.createTreeWalker(form, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let label = '';
    for (let n = tw.nextNode(); n; n = tw.nextNode()) {
      if (n.nodeType === 3) {
        const s = n.textContent.replace(/\s+/g, ' ').trim();
        if (s.length > 8 && !/^(\d+\s*h|\d+\s*min|- - -)/.test(s)) label = s;
      } else if (n.tagName === 'SELECT' && /^inp_/.test(n.name)) {
        const m = /^(\d+(?:\.\d+)*)\.?\s/.exec(label);
        acts.push({ name: n.name, code: m ? m[1] : n.name, label });
      }
    }
    const mm = /(?:Hores m[àa]ximes|Horas m[áa]ximas|Max(?:imum)? hours)\s*:?\s*(\d+(?:[.,]\d+)?)\s*H/i.exec(
      form.textContent
    );
    return { form, acts, max: mm ? parseFloat(mm[1].replace(',', '.')) : null };
  }

  function baseParams(form) {
    const p = new URLSearchParams();
    [...form.elements].forEach((e) => {
      if (!e.name || e.tagName === 'BUTTON' || e.type === 'button' || e.type === 'submit') return;
      if (e.tagName === 'SELECT' && e.multiple) return;
      if ((e.type === 'checkbox' || e.type === 'radio') && !e.checked) return;
      p.set(e.name, e.value || '');
    });
    return p;
  }

  function optionValueForHours(select, hours) {
    const o = [...select.options].find((x) => x.value !== '' && Number(x.value) === hours);
    return o ? o.value : null;
  }

  async function saveDay(href, plan, forcedTotal) {
    const doc = await getDoc(href);
    const info = readDayForm(doc);
    const p = baseParams(info.form);
    let total = 0;
    info.acts.forEach((a) => p.set(a.name, '0'));
    for (const name of Object.keys(plan)) {
      const sel = info.form.querySelector(`[name="${name}"]`);
      const v = optionValueForHours(sel, plan[name]);
      if (v === null) throw new Error(`Sin opción de ${plan[name]}h en ${name}`);
      p.set(name, v);
      total += plan[name];
    }
    p.set('moduleaction', 'save');
    p.set('horesConsignades', String(forcedTotal != null ? forcedTotal : total));
    return postForm(DAY_PATH, p);
  }

  async function saveReport(href, ratingValue) {
    const doc = await getDoc(href);
    const form = doc.getElementById('workingForm');
    const p = baseParams(form);
    form.querySelectorAll('select[name^="inp_"]').forEach((s) => {
      const has = [...s.options].some((o) => o.value === ratingValue);
      if (has) p.set(s.name, ratingValue);
    });
    p.set('moduleaction', 'save');
    return postForm(REPORT_PATH, p);
  }

  /* ------------------------------------------------------------------ *
   *  Panel
   * ------------------------------------------------------------------ */

  const old = document.getElementById('sbid-autofill');
  if (old) old.remove();

  const css = `
    #sbid-autofill{position:fixed;top:8px;right:8px;width:400px;max-height:94vh;overflow:auto;z-index:2147483647;
      background:#fff;color:#111;font:13px/1.4 system-ui,sans-serif;border:1px solid #888;border-radius:8px;
      box-shadow:0 6px 24px rgba(0,0,0,.3);padding:10px}
    #sbid-autofill h3{margin:0 0 8px;font-size:15px;display:flex;justify-content:space-between}
    #sbid-autofill label{display:flex;justify-content:space-between;align-items:center;gap:8px;margin:3px 0}
    #sbid-autofill input[type=number],#sbid-autofill input[type=text],#sbid-autofill input[type=date],#sbid-autofill select{width:150px;box-sizing:border-box}
    #sbid-autofill button{margin:4px 4px 4px 0;padding:4px 10px;cursor:pointer}
    #sbid-autofill .acts{max-height:200px;overflow:auto;border:1px solid #ccc;padding:4px;margin:4px 0}
    #sbid-autofill .acts label{justify-content:flex-start}
    #sbid-autofill .acts input[type=number]{width:46px}
    #sbid-autofill pre{background:#f4f4f4;max-height:200px;overflow:auto;margin:6px 0 0;padding:6px;white-space:pre-wrap;font-size:12px}
    @media (prefers-color-scheme:dark){#sbid-autofill{background:#1e1e1e;color:#eee}#sbid-autofill pre{background:#111}}
  `;

  const root = document.createElement('div');
  root.id = 'sbid-autofill';
  root.innerHTML = `<style>${css}</style>
    <h3><span>${t.title}</span><button data-x title="close">×</button></h3>
    <label>${t.hours}<input type="number" step="0.25" min="0.25" data-k="hours"></label>
    <label>${t.minBlock}<input type="number" step="0.25" min="0.25" value="0.5" data-k="minBlock"></label>
    <label>${t.kMin}<input type="number" min="1" value="2" data-k="kMin"></label>
    <label>${t.kMax}<input type="number" min="1" value="3" data-k="kMax"></label>
    <label>${t.seed}<input type="text" value="sbid" data-k="seed"></label>
    <label>${t.before}<input type="date" data-k="before"></label>
    <label>${t.weekends}<input type="checkbox" checked data-k="weekends"></label>
    <label>${t.reports}<input type="checkbox" checked data-k="reports"></label>
    <label>${t.rating}<select data-k="rating"><option value="">${t.auto}</option></select></label>
    <label>${t.dry}<input type="checkbox" checked data-k="dry"></label>
    <div><button data-scan>${t.scan}</button></div>
    <div data-actsbox hidden>
      <b>${t.acts}</b>
      <label>${t.kw}<input type="text" data-k="kw" placeholder="seguretat, base de dades"></label>
      <div><button data-kwbtn>${t.kwBtn}</button><button data-all>${t.all}</button><button data-none>${t.none}</button></div>
      <div class="acts" data-acts></div>
    </div>
    <div><button data-run>${t.run}</button><button data-stop disabled>${t.stop}</button></div>
    <pre data-log></pre>`;
  document.body.appendChild(root);

  const $ = (s) => root.querySelector(s);
  const val = (k) => {
    const e = root.querySelector(`[data-k="${k}"]`);
    return e.type === 'checkbox' ? e.checked : e.value;
  };
  const logEl = $('[data-log]');
  const log = (s) => {
    logEl.textContent += s + '\n';
    logEl.scrollTop = logEl.scrollHeight;
  };

  const today = new Date();
  $('[data-k="before"]').value = [today.getFullYear(), String(today.getMonth() + 1).padStart(2, '0'), String(today.getDate()).padStart(2, '0')].join('-');

  let scanned = null; // {acts:[{name,code,label}], max}

  $('[data-x]').onclick = () => root.remove();

  $('[data-scan]').onclick = async () => {
    try {
      const ag = await getAgenda();
      const href = (ag.items.find((x) => x.kind === 'day') || {}).href || ag.anyDay;
      if (!href) return log(t.noForm);
      const info = readDayForm(await getDoc(href));
      if (!info || !info.acts.length) return log(t.noForm);
      scanned = { acts: info.acts, max: info.max };
      if (info.max) $('[data-k="hours"]').value = info.max;
      const box = $('[data-acts]');
      box.innerHTML = '';
      info.acts.forEach((a, i) => {
        const l = document.createElement('label');
        l.innerHTML = `<input type="checkbox" data-a="${i}" checked><input type="number" min="1" max="10" value="1" data-w="${i}"><span title="${a.label.replace(/"/g, '')}">${a.label.slice(0, 48)}</span>`;
        box.appendChild(l);
      });
      $('[data-actsbox]').hidden = false;
      log(t.scanned(info.acts.length, info.max));

      const rep = ag.items.find((x) => x.kind === 'report');
      if (rep) {
        const form = (await getDoc(rep.href)).getElementById('workingForm');
        const sel = form && form.querySelector('select[name^="inp_"]');
        if (sel) {
          const rs = $('[data-k="rating"]');
          [...sel.options].filter((o) => o.value !== '').forEach((o) => {
            const op = document.createElement('option');
            op.value = o.value;
            op.textContent = o.textContent.trim();
            rs.appendChild(op);
          });
        }
      }
    } catch (e) {
      log('Error: ' + e.message);
    }
  };

  const setAll = (on) =>
    root.querySelectorAll('[data-a]').forEach((c) => {
      c.checked = on;
    });
  $('[data-all]').onclick = () => setAll(true);
  $('[data-none]').onclick = () => setAll(false);
  $('[data-kwbtn]').onclick = () => {
    const kws = val('kw').split(',').map((s) => norm(s.trim())).filter(Boolean);
    if (!kws.length || !scanned) return;
    scanned.acts.forEach((a, i) => {
      const hit = kws.some((k) => norm(a.label).includes(k));
      root.querySelector(`[data-a="${i}"]`).checked = hit;
      root.querySelector(`[data-w="${i}"]`).value = hit ? 3 : 1;
    });
  };

  let stopped = false;
  $('[data-stop]').onclick = () => {
    stopped = true;
  };

  $('[data-run]').onclick = async () => {
    if (!scanned) return log(t.needScan);
    const cfg = {
      hours: parseFloat(val('hours')),
      minBlock: parseFloat(val('minBlock')),
      kMin: parseInt(val('kMin'), 10),
      kMax: parseInt(val('kMax'), 10),
      seed: val('seed'),
      before: val('before') ? new Date(val('before') + 'T00:00:00') : null,
      weekends: val('weekends'),
      reports: val('reports'),
      rating: val('rating'),
      dry: val('dry'),
    };
    const acts = scanned.acts
      .map((a, i) => ({
        id: a.name,
        code: a.code,
        weight: root.querySelector(`[data-a="${i}"]`).checked ? parseFloat(root.querySelector(`[data-w="${i}"]`).value) || 1 : 0,
      }))
      .filter((a) => a.weight > 0);
    if (!acts.length) return log(t.noActs);

    const first = await getAgenda();
    if (!first.items.length) return log(t.nothing);
    if (!cfg.dry && !confirm(t.confirm(first.count, cfg.hours))) return;

    $('[data-run]').disabled = true;
    $('[data-stop]').disabled = false;
    stopped = false;
    try {
      await run(cfg, acts);
    } catch (e) {
      log('Error: ' + e.message);
    }
    $('[data-run]').disabled = false;
    $('[data-stop]').disabled = true;
  };

  async function run(cfg, acts) {
    const rng = mulberry32(hashSeed(cfg.seed));
    const skip = new Set();
    const codeOf = Object.fromEntries(acts.map((a) => [a.id, a.code]));
    let done = 0;
    for (let guard = 0; guard < 1000; guard++) {
      if (stopped) return log(t.stopped);
      const ag = await getAgenda();
      const it = ag.items.find((x) => !skip.has(x.href));
      if (!it) return log(`${t.done} (${done})`);

      const late = cfg.before && it.date && it.date >= cfg.before;
      if (late || (it.kind === 'day' && cfg.weekends && it.date && isWeekend(it.date)) || (it.kind === 'report' && !cfg.reports)) {
        skip.add(it.href);
        log(`${t.skipped}: ${it.text}`);
        continue;
      }

      if (it.kind === 'day') {
        const info = readDayForm(await getDoc(it.href));
        const total = Math.min(cfg.hours, info.max || cfg.hours);
        const plan = distribute(rng, acts, {
          total,
          minBlock: cfg.minBlock,
          kMin: cfg.kMin,
          kMax: cfg.kMax,
          maxPerAct: info.max || total,
        });
        const summary = Object.keys(plan).map((id) => `${codeOf[id]}:${plan[id]}h`).join(' ');
        if (cfg.dry) {
          skip.add(it.href);
          log(`[dry] ${t.day} ${it.text.slice(0, 10)} → ${summary}`);
          done++;
          continue;
        }
        const st = await saveDay(it.href, plan);
        const after = await getAgenda();
        if (st >= 400 || after.items.some((x) => x.href === it.href)) return log(t.stuck + ' ' + it.text);
        log(`${t.day} ${it.text.slice(0, 10)} → ${summary}`);
        done++;
      } else {
        const form = (await getDoc(it.href)).getElementById('workingForm');
        const sel = form.querySelector('select[name^="inp_"]');
        const opts = [...sel.options].map((o) => ({ value: o.value, text: o.textContent.trim() }));
        const rating = cfg.rating || pickBestRating(opts);
        if (cfg.dry) {
          skip.add(it.href);
          log(`[dry] ${t.report} ${it.text.slice(0, 10)} → ${(opts.find((o) => o.value === rating) || {}).text}`);
          done++;
          continue;
        }
        const st = await saveReport(it.href, rating);
        const after = await getAgenda();
        if (st >= 400 || after.items.some((x) => x.href === it.href)) return log(t.stuck + ' ' + it.text);
        log(`${t.report} ${it.text.slice(0, 10)} → ${(opts.find((o) => o.value === rating) || {}).text}`);
        done++;
      }
      await new Promise((r) => setTimeout(r, 250));
    }
  }
})();
