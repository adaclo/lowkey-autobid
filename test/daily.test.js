// Prueba de integración de windows/sbid-daily.ps1 contra un sBID simulado (HTTP real en localhost). Solo Windows.
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');

const ACTS = [
  ['101', '1.3. Participació en la gestió de recursos en xarxa identificant les restriccions de seguretat.'],
  ['102', '1.4. Utilització d’aplicacions informàtiques per elaborar documentació tècnica.'],
  ['103', '1.5. Utilització d’entorns de desenvolupament per editar, depurar i provar codi.'],
  ['104', '2.4. Execució de consultes directes i procediments sobre la base de dades.'],
  ['105', '2.8. Elaboració de la documentació associada a la gestió de les bases de dades.'],
];
const HOURS = [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3, 3.25, 3.5, 3.75, 4];
const hoursOptions = HOURS.map((h) => `<option value="${h === Math.floor(h) ? h.toFixed(1) : h}">${h}</option>`).join('');
const ratingOptions = '<option value="">- Seleccionar -</option><option value="33">SENSE VALORACIÓ</option><option value="30">ADEQUADA</option><option value="29">MOLT ADEQUADA</option>';

function startMock(pending) {
  const state = { loggedIn: new Set(), saved: {}, reports: {}, pending: pending.slice(), logins: 0, rejectDaySave: false };
  const fmt = (d) => `${d.slice(6, 8)}/${d.slice(4, 6)}/${d.slice(0, 4)}`;
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    const cookie = (req.headers.cookie || '').match(/JSESSIONID=(\w+)/);
    const sid = cookie && cookie[1];
    const send = (code, body, headers = {}) => {
      res.writeHead(code, { 'Content-Type': 'text/html', ...headers });
      res.end(body);
    };
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const body = new URLSearchParams(raw);
      const authed = sid && state.loggedIn.has(sid);
      if (u.pathname === '/sBid/modules/Login' && req.method === 'GET') return send(200, '<form id="loginForm"></form>', { 'Set-Cookie': 'JSESSIONID=abc123; Path=/sBid' });
      if (u.pathname === '/sBid/modules/Login' && req.method === 'POST') {
        state.logins++;
        if (body.get('username') === 'alumne' && body.get('password') === 'secret' && body.get('moduleaction') === 'doLogin') {
          state.loggedIn.add('abc123');
          return send(302, '', { Location: '/sBid/modules/Agenda?moduleaction=show' });
        }
        return send(200, '<form id="loginForm"></form>');
      }
      if (u.pathname === '/sBid/jsp/doLogout.jsp') {
        state.loggedIn.clear();
        return send(200, 'bye');
      }
      if (!authed) return send(200, '<form id="loginForm"></form>');

      if (u.pathname === '/sBid/modules/Agenda') {
        const items = state.pending.slice(0, 3).map((p) =>
          p.report
            ? `<li><a href="/sBid/modules/ActivitatValoracioFct?moduleaction=show&amp;pk=${p.date}&amp;hash_code=h${p.date}">${fmt(p.date)}: Informe periòdic (1)</a></li>`
            : `<li><a href="/sBid/modules/ActivitatFct?moduleaction=show&amp;codi_conveni=1&amp;data=${p.date}&amp;hash_code=h${p.date}">${fmt(p.date)}: Activitat diària del dossier (1)</a></li>`
        );
        return send(200, `<div id="heading1"><span class="badge">${state.pending.length}</span></div><div id="collapse1"><ul>${items.join('')}</ul></div>`);
      }
      if (u.pathname === '/sBid/modules/ActivitatFct' && req.method === 'GET') {
        const acts = ACTS.map(([id, label]) => `<div>${label}</div><select name="inp_${id}">${hoursOptions}</select>`).join('');
        return send(200, `<form id="workingForm"><input type="hidden" name="moduleaction" value=""><input type="hidden" name="data" value="${u.searchParams.get('data')}"><input type="hidden" name="hash_code" value="${u.searchParams.get('hash_code')}"><input type="hidden" name="horesConsignades" value="0"><div>Hores màximes:<br>4H</div>${acts}</form>`);
      }
      if (u.pathname === '/sBid/modules/ActivitatFct' && req.method === 'POST') {
        const total = [...body.entries()].filter(([k]) => k.startsWith('inp_')).reduce((t, [, v]) => t + Number(v), 0);
        if (state.rejectDaySave || body.get('moduleaction') !== 'save' || total > 4 || total !== Number(body.get('horesConsignades')) || body.get('hash_code') !== 'h' + body.get('data')) return send(500, 'no');
        state.saved[body.get('data')] = Object.fromEntries([...body.entries()].filter(([k, v]) => k.startsWith('inp_') && v !== '0'));
        state.pending = state.pending.filter((p) => p.report || p.date !== body.get('data'));
        return send(200, 'ok');
      }
      if (u.pathname === '/sBid/modules/ActivitatValoracioFct' && req.method === 'GET') {
        const sel = ACTS.map(([id]) => `<select name="inp_${id}">${ratingOptions}</select>`).join('');
        return send(200, `<form id="workingForm"><input type="hidden" name="moduleaction"><input type="hidden" name="pk" value="${u.searchParams.get('pk')}">${sel}</form>`);
      }
      if (u.pathname === '/sBid/modules/ActivitatValoracioFct' && req.method === 'POST') {
        state.reports[body.get('pk')] = [...body.entries()].filter(([k]) => k.startsWith('inp_')).map(([, v]) => v);
        state.pending = state.pending.filter((p) => !(p.report && p.date === body.get('pk')));
        return send(200, 'ok');
      }
      send(404, 'nf');
    });
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({ server, state, baseUrl: `http://127.0.0.1:${server.address().port}` })));
}

/*TESTS*/
const SCRIPT = path.join(__dirname, '..', 'windows', 'sbid-daily.ps1');
const winOnly = { skip: process.platform !== 'win32' && 'requiere Windows PowerShell' };
const day = (date) => ({ date });
const report = (date) => ({ date, report: true });

function runPs(m, cfgOverrides, { now = '2026-06-08T09:00:00', flags = [] } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sbid-'));
  const cfg = { Username: 'alumne', Password: 'secret', Seed: 't', FillTodayAfter: '18:00', NetworkRetries: 0, NetworkRetryDelaySeconds: 0, Notify: 'none', Activities: { '1.4': 2, '1.5': 3, '2.4': 3, '2.8': 2 }, ...cfgOverrides };
  const ps = (v) => (Array.isArray(v) ? `@(${v.map(ps).join(',')})` : typeof v === 'object' ? `@{${Object.entries(v).map(([k, x]) => `'${k}'=${ps(x)}`).join(';')}}` : typeof v === 'string' ? `'${v}'` : typeof v === 'boolean' ? (v ? '$true' : '$false') : v);
  const cfgFile = path.join(dir, 'config.ps1');
  fs.writeFileSync(cfgFile, `$Config = ${ps(cfg)}\n`);
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-ConfigPath', cfgFile, '-LogFile', path.join(dir, 'log.txt'), '-BaseUrl', m.baseUrl, '-Now', now, ...flags];
  return new Promise((resolve) => execFile('powershell', args, { timeout: 120000 }, (err, stdout, stderr) => resolve({ code: err ? err.code : 0, out: stdout + stderr })));
}
const sumDay = (d) => Object.values(d).reduce((t, v) => t + Number(v), 0);

test('rellena días e informes, salta fines de semana y el futuro', winOnly, async () => {
  // 2026-06-01 lun … 06-05 vie, 06-06/07 fin de semana, 06-08 lun (hoy), 06-09 mañana
  const m = await startMock([day('20260601'), day('20260602'), report('20260602'), day('20260605'), day('20260606'), day('20260607'), day('20260608'), day('20260609')]);
  try {
    const r = await runPs(m, {});
    assert.equal(r.code, 0, r.out);
    assert.deepEqual(Object.keys(m.state.saved).sort(), ['20260601', '20260602', '20260605'], r.out);
    for (const d of Object.keys(m.state.saved)) {
      assert.equal(sumDay(m.state.saved[d]), 4);
      const ids = Object.keys(m.state.saved[d]);
      assert.ok(ids.length >= 2 && ids.length <= 3);
      ids.forEach((id) => assert.ok(['inp_102', 'inp_103', 'inp_104', 'inp_105'].includes(id), 'solo actividades con peso: ' + id));
    }
    assert.deepEqual(m.state.reports['20260602'], ['29', '29', '29', '29', '29']);
    assert.match(r.out, /Hecho: 4 guardados/);
    assert.equal(m.state.loggedIn.size, 0, 'cierra sesión');
  } finally {
    m.server.close();
  }
});

test('rellena hoy solo si ya pasó FillTodayAfter', winOnly, async () => {
  const m = await startMock([day('20260608')]);
  try {
    await runPs(m, {}, { now: '2026-06-08T17:59:00' });
    assert.deepEqual(Object.keys(m.state.saved), []);
    await runPs(m, {}, { now: '2026-06-08T18:01:00' });
    assert.deepEqual(Object.keys(m.state.saved), ['20260608']);
  } finally {
    m.server.close();
  }
});

test('SkipDates, MaxPerRun y misma semilla = mismo reparto', winOnly, async () => {
  const days = ['20260601', '20260602', '20260603', '20260604'].map(day);
  const run = async (extra) => {
    const m = await startMock(days);
    try {
      const r = await runPs(m, extra, { now: '2026-07-01T09:00:00' });
      return { r, saved: m.state.saved };
    } finally {
      m.server.close();
    }
  };
  const a = await run({ SkipDates: ['2026-06-02'], MaxPerRun: 2 });
  assert.deepEqual(Object.keys(a.saved).sort(), ['20260601', '20260603'], a.r.out);
  assert.match(a.r.out, /tope/);
  const b = await run({});
  assert.deepEqual(Object.keys(b.saved).length, 4, b.r.out);
  assert.deepEqual(b.saved['20260601'], a.saved['20260601']);
});

test('-DryRun no guarda nada y enseña el reparto', winOnly, async () => {
  const m = await startMock([day('20260601'), report('20260601')]);
  try {
    const r = await runPs(m, {}, { now: '2026-07-01T09:00:00', flags: ['-DryRun'] });
    assert.deepEqual(m.state.saved, {});
    assert.match(r.out, /\[dry-run\] 2026-06-01 -> [\d.]+:/);
    assert.match(r.out, /\[dry-run\] informe .* MOLT ADEQUADA/);
    assert.match(r.out, /2 simulados/);
  } finally {
    m.server.close();
  }
});

test('login incorrecto: sale con error y no reintenta', winOnly, async () => {
  const m = await startMock([day('20260601')]);
  try {
    const r = await runPs(m, { Password: 'mala', NetworkRetries: 3 });
    assert.equal(r.code, 1);
    assert.match(r.out, /login rechazado/);
    assert.equal(m.state.logins, 1);
  } finally {
    m.server.close();
  }
});

test('si sBID rechaza un guardado, se detiene', winOnly, async () => {
  const m = await startMock([day('20260601'), day('20260602')]);
  m.state.rejectDaySave = true;
  try {
    const r = await runPs(m, {}, { now: '2026-07-01T09:00:00' });
    assert.deepEqual(m.state.saved, {});
    assert.match(r.out, /Parado: sBID no ha aceptado/);
  } finally {
    m.server.close();
  }
});

test('-Check solo cuenta, no guarda', winOnly, async () => {
  const m = await startMock([day('20260601')]);
  try {
    const r = await runPs(m, {}, { now: '2026-07-01T09:00:00', flags: ['-Check'] });
    assert.deepEqual(m.state.saved, {});
    assert.match(r.out, /Pendientes segun la Agenda: 1/);
  } finally {
    m.server.close();
  }
});

test('-Startup con salida redirigida: sin panel, mismo resultado', winOnly, async () => {
  const m = await startMock([day('20260601')]);
  try {
    const r = await runPs(m, { StartDelaySeconds: 0 }, { now: '2026-07-01T09:00:00', flags: ['-Startup'] });
    assert.equal(r.code, 0, r.out);
    assert.deepEqual(Object.keys(m.state.saved), ['20260601']);
    assert.match(r.out, /Arranque: espero 0s/);
  } finally {
    m.server.close();
  }
});
