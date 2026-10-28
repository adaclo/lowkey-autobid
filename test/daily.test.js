// Prueba de integración de windows/sbid-daily.ps1 contra un sBID simulado (HTTP real en localhost). Solo Windows.
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');

const { startMock } = require('../dev/mock-sbid.js');
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

// ---------------------------------------------------------------- setup.ps1 (asistente)
const SETUP = path.join(__dirname, '..', 'windows', 'setup.ps1');

function runSetup(m, { keys, inputs, env = {} }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sbid-setup-'));
  const cfgFile = path.join(dir, 'config.ps1');
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SETUP, '-ConfigPath', cfgFile, '-BaseUrl', m.baseUrl];
  const e = { ...process.env, SBID_USER: 'alumne', SBID_PASS: 'secret', SBID_SETUP_KEYS: keys, SBID_SETUP_INPUT: inputs, ...env };
  return new Promise((resolve) => execFile('powershell', args, { timeout: 120000, env: e }, (err, stdout, stderr) => resolve({ code: err ? err.code : 0, out: stdout + stderr, cfgFile })));
}
const answers = (...a) => a.join('|');
const ENTER_ALL = answers('', '', '', '', '', '', '', '', '', '', '', '', 'n', 'n'); // 12 respuestas por defecto + no simular + no instalar

test('setup: lee las actividades del usuario, genera config.ps1 y el script diario lo usa', winOnly, async () => {
  const m = await startMock([day('20260601'), report('20260601'), day('20260602')]);
  try {
    const r = await runSetup(m, { keys: 'Spacebar,DownArrow,Spacebar,RightArrow,RightArrow,Enter', inputs: ENTER_ALL });
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /Login correcto/);
    assert.match(r.out, /5 en tu plan/);
    assert.match(r.out, /Max\. por dia: 4 h/);
    assert.match(r.out, /2 actividades elegidas/);
    const cfg = fs.readFileSync(r.cfgFile, 'utf8');
    assert.match(cfg, /'1\.3'\s*= 1/);
    assert.match(cfg, /'1\.4'\s*= 3/);
    assert.doesNotMatch(cfg, /'1\.5'/);
    assert.match(cfg, /PasswordProtected = '[0-9a-f]{20,}/);
    assert.doesNotMatch(cfg, /secret/, 'la contraseña no debe aparecer en claro');
    assert.match(cfg, /Rating\s+= 'auto'/);
    assert.match(cfg, /FillTodayAfter = '18:00'/);

    // el config generado funciona con el script diario (contraseña cifrada incluida)
    fs.writeFileSync(r.cfgFile, cfg.replace("Notify         = 'changes'", "Notify         = 'none'"), 'utf8');
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-ConfigPath', r.cfgFile, '-LogFile', path.join(path.dirname(r.cfgFile), 'log.txt'), '-BaseUrl', m.baseUrl, '-Now', '2026-07-01T09:00:00'];
    const d = await new Promise((resolve) => execFile('powershell', args, { timeout: 120000 }, (err, so, se) => resolve({ code: err ? err.code : 0, out: so + se })));
    assert.equal(d.code, 0, d.out);
    assert.deepEqual(Object.keys(m.state.saved).sort(), ['20260601', '20260602'], d.out);
    for (const day of Object.values(m.state.saved)) {
      assert.deepEqual(Object.keys(day).sort(), ['inp_101', 'inp_102'], 'solo las 2 actividades elegidas');
      assert.equal(sumDay(day), 4);
    }
    assert.deepEqual(m.state.reports['20260601'], ['29', '29', '29', '29', '29']);
  } finally {
    m.server.close();
  }
});

test('setup: Esc cancela y no escribe nada', winOnly, async () => {
  const m = await startMock([day('20260601')]);
  try {
    const r = await runSetup(m, { keys: 'Escape', inputs: '|' }); // una respuesta vacia (palabras clave); una variable de entorno vacia no existe en Windows
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /Cancelado/);
    assert.equal(fs.existsSync(r.cfgFile), false);
  } finally {
    m.server.close();
  }
});

test('setup: palabras clave preseleccionan, fechas con rangos y contraseña en claro si se pide', winOnly, async () => {
  const m = await startMock([day('20260601')]);
  try {
    // kw=seguretat -> marca 1.3; hours=3; min=1; acts=1-1; weekends=n; skip=rango; fillToday=no; reports=n; protect=n; panel=n; guardar; no sim; no instalar
    const r = await runSetup(m, {
      keys: 'Enter',
      inputs: answers('seguretat', '3', '1', '1-1', 'n', '2026-12-24..2026-12-26, 2027-01-06', 'no', 'n', 'n', 'n', '', 'n', 'n'),
    });
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /1 actividades coinciden/);
    const cfg = fs.readFileSync(r.cfgFile, 'utf8');
    assert.match(cfg, /HoursPerDay = 3/);
    assert.match(cfg, /MinBlock\s+= 1/);
    assert.match(cfg, /MinActs\s+= 1/);
    assert.match(cfg, /MaxActs\s+= 1/);
    assert.match(cfg, /'1\.3'\s*= 3/);
    assert.match(cfg, /Password = 'secret'/);
    assert.match(cfg, /SkipWeekends   = \$false/);
    assert.match(cfg, /SkipDates\s+= @\('2026-12-24', '2026-12-25', '2026-12-26', '2027-01-06'\)/);
    assert.match(cfg, /FillTodayAfter = ''/);
    assert.match(cfg, /FillReports    = \$false/);
  } finally {
    m.server.close();
  }
});

test('setup: login incorrecto con credenciales de entorno sale con error', winOnly, async () => {
  const m = await startMock([day('20260601')]);
  try {
    const r = await runSetup(m, { keys: 'Enter', inputs: '', env: { SBID_PASS: 'mala' } });
    assert.equal(r.code, 1);
    assert.match(r.out, /usuario o contrasenya incorrectos/);
    assert.equal(fs.existsSync(r.cfgFile), false);
    assert.equal(m.state.logins, 1, 'un solo intento');
  } finally {
    m.server.close();
  }
});
